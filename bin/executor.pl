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
use Data::Dumper;

use POSIX ":sys_wait_h";
use EV;
use AnyEvent;

use AnyEvent::Log;
use AnyEvent::WebSocket::Client;
use Cpanel::JSON::XS;

use Config::Any::INI;
use Getopt::Long qw/GetOptions/;

use URI;
use File::Spec;
use Digest::MD5 qw/md5_hex/;

my $log = AnyEvent::Log::logger info => \my $info;

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

$log->("command : " . $command);
$log->("return_url : " . $return_url);

# !Doing bad things here
# We are using return URI to get parts and connect via WebSocket
my $uri = URI->new($return_url);
my ( $host, $port, $path ) = ( $uri->host(), $uri->port(), $uri->path() );
$host = '127.0.0.1' if ($host eq '*');
my ( $token ) = $return_url =~ /\/command\/(.*)$/;


# Separate log for the command
my $token_safe_name = $token;
$token_safe_name =~ s/=//g;

# my $action_log = AnyEvent->logger("action_$token_safe_name.txt");
my $action_log = AnyEvent::Log::logger info => \my $action;
$action_log->("Started with return url $return_url");

if (! $return_url) {
    print `$command`;
    exit $!;
}

# Fine grained response handling (dies on connection errors)
my $ua = AnyEvent::WebSocket::Client->new;

my $handle;
my $timer;
my $seek_timer;

$ua->connect("ws://$host:$port/ws")->cb(sub {

    our $tx = eval {shift->recv};
    if ($@) {
        # handle error...
        warn $@;
        return;
    }

    # recieve message from the websocket...
    $tx->on(each_message => sub {
        # $connection is the same connection object
        # $message isa AnyEvent::WebSocket::Message
        my ( $connection, $message ) = @_;

        my $hash = decode_json($message->decoded_body());
        say "received:" . $message->body();

        if ($hash->{type} eq 'action_cancelled') {
            stop_action($tx);
            $tx->close();
            exit(0);
        }
        if ($hash->{type} eq 'ping') {
            send_message($tx, {
                type => 'pong',
                seq  => $hash->{seq}
            })
        }
        else {
            say "Unregistered message " . Dumper $hash;
        }

    });

    say "Starting action";
    my ( $child_pid, $cfh ) = start_action($tx);
    if ($child_pid && $cfh) {
        say "Child pid is received";
        send_message($tx, {
            type      => 'worker_action_started',
            pid       => $$,
            child_pid => $child_pid
        });

        $timer = wait_for_child($child_pid,
            sub {
                my $current_code = shift;
                send_message($tx, {
                    type      => 'worker_child_running',
                    child_pid => $child_pid,
                    code      => $current_code
                });

            },
            sub {
                send_message($tx, {
                    type      => 'worker_child_finished',
                    child_pid => $child_pid
                });

                print STDERR "FINISHED:";
                close($cfh);
            }
        );
    }
    else {
        die "Failed to get pid or run file\n";
    }

});


sub start_action {
    my ( $tx ) = @_;

    my $someTemporaryFile = "./test_$token_safe_name.txt";
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
            # seek($cfh, $current_seek_pos, SEEK_SET);

            my $content = '';
            my $read_bytes = read($cfh, $content, 1024 * 1024, $current_seek_pos);

            if ($read_bytes) {
                # Remembering the pos
                $current_seek_pos += $read_bytes;

                $action_log->($content);

                send_message($tx, {
                    type    => 'worker_output',
                    content => $content
                });
            }

            # Clear EOF
            seek($cfh, 0, SEEK_CUR);
        }
    );

    return $seek_timer;
}

sub wait_for_child {
    my ( $pid, $run_cb, $finished_cb ) = @_;

    $timer = AnyEvent->timer(after => 1, interval => 0, cb => sub {
        my $exit_code = waitpid($pid, WNOHANG);
        if ($exit_code == 0) {
            $run_cb->($exit_code);
            wait_for_child($pid, $run_cb, $finished_cb);
        }
        else {
            $finished_cb->($exit_code);
        }
    });
}

sub send_message {
    my ( $tx, $msg ) = @_;
    $msg->{token} = $token;
    eval {
        my $json = encode_json($msg);
        $tx->send($json);
        $action_log->("Message sent: $msg->{type};\n");
        1;
    } or do {
        die "Failed to send a message: $@\n";
    }
}

EV::run;
print "IOLoop crashed\n";

exit 0;