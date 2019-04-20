#!/usr/bin/env perl
use strict;
use warnings FATAL => 'all';
use feature 'say';

# use threads;
# use Thread::Queue;

use Fcntl qw(:seek);

$| = 1;

our $Bin;
BEGIN {
    use FindBin '$Bin';
    # unshift @INC, $Bin . '/../lib/';
}
use POSIX ":sys_wait_h";
use AnyEvent::Impl::Perl;
use AnyEvent;
use AnyEvent::Handle;
use AE;

use Mojo::Log;
use Mojo::UserAgent;

use File::Spec;

use Data::Dumper;
use Config::Any::INI;
use Getopt::Long qw/GetOptions/;

use URI;
use Digest::MD5 qw/md5_hex/;

my $log = Mojo::Log->new()->path('cmd_log.txt');

my $command = '';
my $return_url = '';
my $cfg_path = $Bin . '/../config.ini';

GetOptions(
    'command=s'   => \$command,
    'returnUrl=s' => \$return_url,
    'config=s'    => \$cfg_path
);

$command =~ s/^'+//;
$command =~ s/'+$//;

die "Usage:
  executor.pl --command \"<command to run>\" [ --returnUrl < http|https url to POST output and results > ] [ --config <pathToConfigFile> ]
  \n" unless $command;

# die "Config is not found at $cfg_path" unless (-e $cfg_path);
#
# my $full_config = Config::Any::INI->load($cfg_path);
# my $config = $full_config->{Executor};

$log->info("command : " . $command);
$log->info("return_url : " . $return_url);

# !Doing bad things here
# We are using return URI to get parts and connect via WebSocket
my $uri = URI->new($return_url);
my ( $host, $port, $path ) = ( $uri->host(), $uri->port(), $uri->path() );
$host = '127.0.0.1' if ($host eq '*');
my ( $token ) = $return_url =~ /\/command\/(.*)$/;


# Separate log for the command
my $token_safe_name = $token;
$token_safe_name =~ s/=//g;

my $action_log = Mojo::Log->new()->path("action_$token_safe_name.txt");

$action_log->info("Started with return url $return_url");

if (! $return_url) {
    print `$command`;
    exit $!;
}

# Fine grained response handling (dies on connection errors)
my $ua = Mojo::UserAgent->new;

my $handle;
my $timer;
my $seek_timer;

$ua->websocket("ws://$host:$port/ws" => sub {
    my ( $lua, $tx ) = @_;

    say 'WebSocket handshake failed!' and return unless $tx->is_websocket;

    $tx->on(json => sub {
        my ( $ltx, $hash ) = @_;
        if ($hash->{type} eq 'action_cancelled') {
            stop_action($tx);
            $tx->finish;
            exit(0);
        }
        if ($hash->{type} eq 'ping') {
            send_message($tx, {
                type => 'pong',
                seq  => $hash->{seq}
            })
        }
    });

    my ( $child_pid, $cfh ) = start_action($tx);
    if ($child_pid && $cfh) {
        send_message($tx, {
            type      => 'worker_action_started',
            pid       => $$,
            child_pid => $child_pid
        });

        my $cv = AE::cv();
        $timer = wait_for_child($child_pid,
            sub {
                my $current_code = shift;
                send_message($tx, {
                    type      => 'worker_child_running',
                    child_pid => $child_pid,
                    code      => $current_code
                });

                # $handle->push_read(line => sub {
                #     my ( $hdl, $line ) = @_;
                #     # print "Got line: '$line'\n";
                #
                #     send_message($tx, {
                #         type    => 'worker_output',
                #         content => $line
                #     });
                # });
            },
            sub {
                send_message($tx, {
                    type      => 'worker_child_finished',
                    child_pid => $child_pid
                });

                close($cfh);
                $cv->send();
            });

        $cv->recv();

        exit 0;
    }
    else {

        die "Failed to get pid or run file\n";
    }

});


sub start_action {
    my ( $tx ) = @_;

    my $someTemporaryFile = "./test_$token_safe_name.txt";
    my $someTemporaryFileabs = File::Spec->rel2abs($someTemporaryFile);

    # Create temprorary file so we are not opening it before it is created by a command

    open(my $tfh, '>', $someTemporaryFile)
        or die "Can't create test file $someTemporaryFile: $@\n";
    # Cleaning file
    print $tfh "";
    close($tfh);

    my $pid = fork();

    if (! defined($pid)) {
        die "Fork failed\n";
    }

    # Running a child
    if ($pid == 0) {
        exit system("$command > $someTemporaryFile");
    }

    # Proceed the parent
    open(my $cfh, '<', "$someTemporaryFile")
        or die "Can't open $someTemporaryFile : $@\n";
    binmode($cfh);

    $handle = setup_handle($cfh, $tx);

    return( $pid, $cfh );
}

sub setup_handle {
    my ( $cfh, $tx ) = @_;

    my $current_seek_pos = 0;

    $seek_timer = AnyEvent->timer(
        after    => 0,
        interval => 1,
        cb       => sub {
            # Return to last position
            seek($cfh, $current_seek_pos, SEEK_SET);

            my $content = '';

            while (my $line = readline($cfh)) {
                chomp($line);
                $content .= $line;
            }

            if ($content) {
                # Remembering the pos
                $current_seek_pos += length($content);

                send_message($tx, {
                    type    => 'worker_output',
                    content => $content
                });
            }

            # Clear EOF
            seek($cfh, 0, SEEK_CUR);
        }
    );

    return $handle;
}

sub wait_for_child {
    my ( $pid, $run_cb, $cb ) = @_;

    $timer = AnyEvent->timer(after => 1, interval => 0, cb => sub {
        my $exit_code = waitpid($pid, WNOHANG);
        if ($exit_code == 0) {
            $run_cb->($exit_code);
            wait_for_child($pid, $run_cb, $cb);
        }
        else {
            $cb->($exit_code);
        }
    });
}

sub stop_action {
    my ( $tx ) = @_;

    $action_log->info("Action cancelled");

    send_message($tx, {
        type   => 'action_canceled',
        reason => 'Server request'
    });
}

sub send_message {
    my ( $tx, $msg ) = @_;
    $msg->{token} = $token;
    eval {
        $tx->send({ json => $msg });
    } or do {
        die "Failed to send a message: $@\n";
    }
}

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

print "IOLoop crashed\n";

exit 0;