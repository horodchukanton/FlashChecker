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
use AnyEvent::Handle;

use Mojo::Log;
use Mojo::UserAgent;

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
my $action_log_path = "action_$token.txt";
$action_log_path =~ s/=//g;
my $action_log = Mojo::Log->new()->path($action_log_path);

$action_log->info("Started with return url $return_url");

if (! $return_url) {
    print `$command`;
    exit $!;
}

# Fine grained response handling (dies on connection errors)
my $ua = Mojo::UserAgent->new;

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

    if (start_action($tx)) {
        send_message($tx, {
            type      => 'worker_action_started',
            operation => 'op_confirm',
            pid       => $$
        });
    }

});

sub start_action {
    my ( $tx ) = @_;

    open(my $cfh, '-|', $command) or do {
        send_message($tx, {
            type   => 'worker_action_failed',
            reason => $@
        });
        exit 1;
    };

    my $handle;
    $handle = AnyEvent::Handle->new(
        fh       => $cfh,
        autocork => 1,
        on_read  => sub {
            my ( $lhandle ) = @_;
            my $read = $lhandle->{rbuf};
            undef $lhandle->{rbuf};

            print "READ";
            send_message($tx, {
                type    => 'worker_output',
                content => $read
            })
        },
        on_eof   => sub {
            print "EOF";
            send_message($tx, {
                type    => 'worker_finished',
                content => ''
            });
        },
        on_error => sub {
            my ( $lfh, $fatal, $message ) = @_;
            print "FATAL: " . $fatal;
            print $message;
            $handle->destroy if $fatal;
        }
    );

    return 1;
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
    $tx->send(json => $msg);
}

Mojo::IOLoop->start unless Mojo::IOLoop->is_running;;