#!/usr/bin/env perl
use strict;
use warnings FATAL => 'all';
use feature 'say';

$| = 1;

our $Bin;
BEGIN {
    use FindBin '$Bin';
    # unshift @INC, $Bin . '/../lib/';
}
use Data::Dumper;

use POSIX qw(WNOHANG);
use Fcntl qw(:seek);

use EV;
use Mojo::Log;
use AnyEvent;
use AnyEvent::WebSocket::Client;

use Cpanel::JSON::XS;
use Getopt::Long qw/GetOptions/;
use URI;

# use Config::Any::INI;
# use File::Spec;


my $command = '';
my $return_url = '';
my $token = '';
my $cfg_path = $Bin . '/../config.ini';

GetOptions(
    'command=s'   => \$command,
    'returnUrl=s' => \$return_url,
    'token=s'     => \$token,
    'config=s'    => \$cfg_path
);

$command =~ s/^'+//;
$command =~ s/'+$//;

die "Usage:
  executor.pl --command \"<command to run>\" [ --returnUrl < http|https url to POST output and results > --token <token> ] [ --config <pathToConfigFile> ]
  \n" unless $command;

# die "Config is not found at $cfg_path" unless (-e $cfg_path);
#
# my $full_config = Config::Any::INI->load($cfg_path);
# my $config = $full_config->{Executor};

# Saving command log
my $cmd_log = Mojo::Log->new()->path("cmd_log.txt");
$cmd_log->info("command : " . $command, "return_url : " . $return_url);

# Separate log for the command
my $token_safe_name = $token;
$token_safe_name =~ s/=//g;

unlink "action_$token_safe_name.txt";
my $action_log = Mojo::Log->new->path("action_$token_safe_name.txt");
$action_log->info("Started with return url: '$return_url'");
if (! $return_url) {
    print `$command`;
    exit $!;
}

my $wait_timer;
my $seek_timer;
my $ua = AnyEvent::WebSocket::Client->new;

$ua->connect($return_url)->cb(sub {
    my $tx = eval {shift->recv};
    if ($@) {
        warn $@;
        die $@;
    }

    # recieve message from the websocket...
    $tx->on(each_message => sub {
        # $connection is the same connection object
        # $message isa AnyEvent::WebSocket::Message
        my ( $connection, $message ) = @_;

        my $hash = decode_json($message->decoded_body());
        say "received:" . $message->{type};

        if ($hash->{type} eq 'action_cancelled') {
            $action_log->info("Action was cancelled");
            exit(0);
        }
        if ($hash->{type} eq 'ping') {
            send_message($tx, {
                type => 'pong',
                seq  => $hash->{seq}
            })
        }
        else {
            $cmd_log->warn("Unregistered message " . Dumper $hash);
        }

    });

    my $child_pid = start_action($tx);
    if ($child_pid) {
        send_message($tx, {
            type      => 'worker_action_started',
            pid       => $$,
            child_pid => $child_pid
        });

        $wait_timer = wait_for_child($child_pid,
            sub {
                my $current_code = shift;
                send_message($tx, {
                    type      => 'worker_child_running',
                    child_pid => $child_pid,
                    code      => $current_code
                });

            },
            sub {
                say "Finished callback";
                undef $wait_timer;

                send_message($tx, {
                    type      => 'worker_child_finished',
                    child_pid => $child_pid
                });
                send_message($tx, {
                    type   => 'disconnect',
                    reason => 'ok'
                });

                # Give some time for message to be sent;
                die;
            }
        );
    }
    else {
        $action_log->debug("Child is free!!!");
        die "Child has to die!";
    }
});

sub start_action {
    my ( $tx ) = @_;

    my $cmd_temp_file = "./test_$token_safe_name.txt";

    # Create temporary file so we are not opening it before it is created by a command
    open(my $tfh, '>', $cmd_temp_file)
        or die "Can't create test file $cmd_temp_file: $@\n";
    # Cleaning file
    print $tfh "";
    close($tfh);

    my $pid = fork();
    if (! defined($pid)) {
        die "Fork failed\n";
    }

    # Running a child
    if ($pid == 0) {
        my $wait_cmd = ( $^O eq 'MSWin32' )
            ? 'timeout /T 5 > NUL'
            : 'sleep 1 > /dev/null';

        exit system("$command > $cmd_temp_file && $wait_cmd");
    }

    open(my $cfh, '<', "$cmd_temp_file")
        or die "Can't open $cmd_temp_file : $@\n";
    binmode($cfh);

    $seek_timer = setup_handle($cfh, $tx);

    return $pid;
}

sub send_new_content {
    my ( $cfh, $tx ) = @_;
    my $content = '';
    my $read_bytes = read($cfh, $content, 1024 * 1024);

    if (! defined $read_bytes) {
        warn "Read error\n";
    }
    elsif ($read_bytes) {
        $action_log->debug("Content:" . $content);

        send_message($tx, {
            type    => 'worker_output',
            content => $content
        });
    }
    else {
        # Clear EOF
        seek($cfh, 0, SEEK_CUR);
    }
}

sub setup_handle {
    my ( $cfh, $tx ) = @_;

    my $timer = AnyEvent->timer(
        after    => 0,
        interval => 0.5,
        cb       => sub {send_new_content($cfh, $tx)}
    );

    return $timer;
}

sub wait_for_child {
    my ( $pid, $run_cb, $finished_cb ) = @_;

    $wait_timer = AnyEvent->timer(after => 0, interval => 1, cb => sub {
        my $exit_code = waitpid($pid, WNOHANG);
        if ($exit_code == 0) {
            undef $wait_timer;
            $run_cb->($exit_code);
            # wait_for_child($pid, $run_cb, $finished_cb);
        }
        elsif ($exit_code == - 1) {
            $action_log->debug("Child was reaped");
            $finished_cb->($exit_code);
        }
        elsif ($exit_code > 1) {
            $action_log->debug("Looks like finished. Exit code is $exit_code");
            $finished_cb->($exit_code);
        }
        else {
            die "Does this exit code looks strange? $exit_code";
        }

    });
}

sub send_message {
    my ( $tx, $msg ) = @_;
    $msg->{token} = $token;
    eval {
        my $json = encode_json($msg);
        $tx->send($json);
        $action_log->debug("Message sent: $msg->{type};");
        1;
    } or do {
        die "Failed to send a message: $@\n";
    }
}

sub me_was_fucked_up {
    # Trying to connect and tell it to the main process

    my $emergency_ua = $ua || AnyEvent::WebSocket::Client->new;
    $emergency_ua->connect($return_url)->cb(sub {
        my $tx = eval {shift->recv};
        if ($@) {
            warn $@;
            return;
        }

        $tx->send(qq/{ "type" : "worker_me_crashed", "token" : "$token" }/);

        exit 0;
    });
}

$SIG{SEGV} = sub {
    print "SEGV\n";
    me_was_fucked_up();
    EV::loop;

};

EV::loop;