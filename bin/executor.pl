#!/usr/bin/perl
use strict;
use warnings FATAL => 'all';
use feature 'say';

$| = 1;

our $Bin;
BEGIN {
    use FindBin '$Bin';
    # unshift @INC, $Bin . '/../lib/';
}


use AnyEvent::Impl::Perl;
use AnyEvent;
use AnyEvent::Util;
use AnyEvent::Handle;
use AE;

use Mojo::Log;
use Mojo::UserAgent;

use File::Spec;

use Win32;
use Win32::Process qw/
    NORMAL_PRIORITY_CLASS
    STILL_ACTIVE
/;

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

$log->info($command);
$log->info($return_url);

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

    if (my $child_pid = start_action($tx)) {
        send_message($tx, {
            type      => 'worker_action_started',
            pid       => $$,
            child_pid => $child_pid
        });

        my $cv = AE::cv();
        $timer = wait_for_child($child_pid,
            sub {
                send_message($tx, {
                    type      => 'worker_child_running',
                    child_pid => $child_pid
                });

                $handle->push_read(line => sub {
                    my ( $hdl, $line ) = @_;
                    # print "Got line: '$line'\n";

                    send_message($tx, {
                        type    => 'worker_output',
                        content => $line
                    });
                });
            },
            sub {
                send_message($tx, {
                    type      => 'worker_child_finished',
                    child_pid => $child_pid
                });
                $cv->send();
            });
        $cv->recv();

        exit 0;
    }
    else {
        die "Failed to get pid\n";
    }

});


sub start_action {
    my ( $tx ) = @_;

    my $test_file = "./test_$token_safe_name.txt";

    my $test_file_abs = File::Spec->rel2abs($test_file);

    -e $test_file_abs or do {
        open(my $tfh, '>', $test_file) or die "Can't create test file $test_file_abs: $@\n";
        close($tfh);
    };

    # my $child_pid = system(1, "$command > $test_file_abs");
    # open(my $cfh, '<', $test_file_abs) or die "Can't open a file $test_file_abs : $@ $!\n";
    print "FILE IS : $test_file_abs\n";

    my $child_pid = open(my $cfh, '-|', $command);

    binmode($cfh);
    $handle = setup_handle($cfh, $tx);

    return $child_pid;
}

sub setup_handle {
    my ( $cfh, $tx ) = @_;

    $handle = AnyEvent::Handle->new(
        fh       => $cfh,
        # read_size => 8,
        # on_read => sub {
        #     my ( $lhandle ) = @_;
        #     my $read = $lhandle->{rbuf};
        #
        #     # print $read;
        #
        #     send_message($tx, {
        #         type    => 'worker_output',
        #         content => $read
        #     });
        #
        #     undef $lhandle->{rbuf};
        # },
        on_eof   => sub {
            print "EOF: \n";
        },
        on_error => sub {
            my ( $lfh, $fatal, $message ) = @_;
            print "Error: " . ( $fatal || '0' ) . ' : ' . $message . "\n";
        }
    );

    return $handle;
}

sub ErrorReport {
    print "IT DIED!!!!!!!1";
    print Win32::FormatMessage(Win32::GetLastError());
}

sub wait_for_child {
    my ( $pid, $run_cb, $cb ) = @_;
    my $exit_code;
    my $process;
    Win32::Process::Open(
        $process, $pid, 0
    ) || die ErrorReport();

    $timer = AnyEvent->timer(after => 1, interval => 0, cb => sub {
        $process->GetExitCode($exit_code);
        if ($exit_code == STILL_ACTIVE) {
            $run_cb->();
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
    print Dumper $msg;
    eval {
        $tx->send({ json => $msg });
    } or do {
        die "Failed to send a message: $@\n";
    }
}

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;

print "IOLoop crashed\n";

exit 0;