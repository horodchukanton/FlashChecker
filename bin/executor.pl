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

use Cpanel::JSON::XS;
use Getopt::Long qw/GetOptions/;
use URI;

use AnyEvent::Impl::Perl;
use Mojo::Log;
use AnyEvent;
use AnyEvent::WebSocket::Client;

# use Config::Any::INI;
# use File::Spec;

my $CHILD_INTERVAL = 10;
my $OUTPUT_INTERVAL = 5;

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

$command ||= '';
$command =~ s/^'+//;
$command =~ s/'+$//;

# Separate log for the command
my $token_safe_name = $token;
$token_safe_name =~ s/=//g;

die "Usage:
  executor.pl --command \"<command to run>\" [ --returnUrl < http|https url to POST output and results > --token <token> ] [ --config <pathToConfigFile> ]
  \n" unless $command;

# die "Config is not found at $cfg_path" unless (-e $cfg_path);
#
# my $full_config = Config::Any::INI->load($cfg_path);
# my $config = $full_config->{Executor};

if (!$return_url) {
    print `$command`;
    exit $!;
}

my $wait_timer;
my $seek_timer;

my ($cfh, $pid) = start_command_in_fork($command);

# Saving command log
{
    my $cmd_log = Mojo::Log->new()->path("cmd_log.txt");
    $cmd_log->info("command : " . $command, " return_url : " . $return_url);
    undef $cmd_log;
}

unlink "action_$token_safe_name.txt";
my $action_log = Mojo::Log->new->path("action_$token_safe_name.txt");
$action_log->info("Started with return url: '$return_url'");

main($return_url, $pid, $cfh);

sub main {
    my ($websocket_url, $child_pid, $child_filehandle) = @_;
    my $connection = connect_to_websocket($websocket_url);
    $connection = setup_connection_service_hadlers($connection, $child_pid);

    my $finish_cv = AnyEvent->condvar();

    # Set wait timer
    $wait_timer = set_wait_for_child_timer($child_pid, $connection, $finish_cv);

    # Set read-and-send timer
    $seek_timer = setup_read_timer($child_filehandle, $connection);

    # Waiting for child to finish
    my $exit_code = $finish_cv->recv();

    # Send last content
    undef $seek_timer;
    undef $wait_timer;

    send_new_content($child_filehandle, $connection);

    close $child_filehandle;

    send_message($connection, {
        type      => 'worker_child_finished',
        child_pid => $pid,
        exit_code => $exit_code
    });

    exit 0;
}

sub start_command_in_fork {
    my ($cmd) = @_;

    my $cmd_temp_file = "./test_$token_safe_name.txt";

    # Create temporary file so we are not opening it before it is created by a command
    open(my $tfh, '>', $cmd_temp_file)
        or die "Can't create test file $cmd_temp_file: $@\n";
    # Cleaning file
    print $tfh "";
    close($tfh);

    my $command_pid = system(1, "$cmd > $cmd_temp_file");

    open(my $fh, '<', "$cmd_temp_file")
        or die "Can't open $cmd_temp_file : $@\n";
    binmode($fh);

    return($fh, $command_pid);
}

sub connect_to_websocket {
    my ($websocket_url) = @_;

    my $ua = AnyEvent::WebSocket::Client->new;

    my $connection_cv = AnyEvent->condvar();
    $ua->connect($websocket_url)->cb(sub {
        my $tx = eval {shift->recv};
        if ($@) {
            warn $@;
            $connection_cv->croak();
            die $@;
        }
        $connection_cv->send($tx);
    });

    return $connection_cv->recv();
}

sub setup_connection_service_hadlers {
    my ($tx, $child_pid) = @_;

    $tx->on(each_message => sub {
        # $connection is the same connection object
        # $message isa AnyEvent::WebSocket::Message
        my ($connection, $message) = @_;

        my $hash = eval {decode_json($message->decoded_body())};
        if ($@) {
            die "Failed to parse message from server\n";
        }

        if ($hash->{type} eq 'action_cancelled') {
            $action_log->info("Action was cancelled");
            kill('INT', $child_pid);
        }
        if ($hash->{type} eq 'ping') {
            send_message($tx, {
                type => 'pong',
                seq  => $hash->{seq}
            })
        }
        else {
            $action_log->warn("Unregistered message " . Dumper $hash);
        }
    });

    return $tx;
}

sub set_wait_for_child_timer {
    my ($child_pid, $tx, $exit_cv) = @_;

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
            my $current_code = shift;
            $exit_cv->send($current_code);
        }
    );
}

sub setup_read_timer {
    my ($child_filehandle, $tx) = @_;

    my $timer = AnyEvent->timer(
        after    => 0,
        interval => $OUTPUT_INTERVAL,
        cb       => sub {send_new_content($child_filehandle, $tx)}
    );

    return $timer;
}

sub send_new_content {
    my ($child_filehandle, $tx) = @_;
    my $content = '';
    my $read_bytes = read($child_filehandle, $content, 1024 * 1024);

    if (!defined $read_bytes) {
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
        seek($child_filehandle, 0, SEEK_CUR);
    }
    return $read_bytes;
}

sub wait_for_child {
    my ($c_pid, $run_cb, $finished_cb) = @_;

    $wait_timer = AnyEvent->timer(after => 0, interval => $CHILD_INTERVAL, cb => sub {
        my $exit_code = waitpid($c_pid, WNOHANG);
        if ($exit_code == 0) {
            $run_cb->($exit_code);
        }
        elsif ($exit_code == -1) {
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
    my ($tx, $msg) = @_;

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