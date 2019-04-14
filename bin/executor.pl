#!/usr/bin/perl
use strict;
use warnings FATAL => 'all';

our $Bin;
BEGIN {
    use FindBin '$Bin';
    # unshift @INC, $Bin . '/../lib/';
}

use Config::Any::INI;
use Getopt::Long qw/GetOptions/;

use AnyEvent::Impl::Perl;
use AnyEvent;
use AnyEvent::Handle;

use URI;
use Data::Dumper;

my $command = 'echo | FORMAT D: /FS:exFAT /Q /X';
my $return_url = '';
my $cfg_path = $Bin . '/../config.ini';

GetOptions(
    'command=s'   => \$command,
    'returnUrl=s' => \$return_url,
    'config=s'    => \$cfg_path
);

die "Usage:
  executor.pl --command \"<command to run>\" [ --returnUrl < http|https url to POST output and results > ] [ --config <pathToConfigFile> ]
  \n" unless $command;

die "Config is not found at $cfg_path" unless (-e $cfg_path);

# my $full_config = Config::Any::INI->load($cfg_path);
# my $config = $full_config->{Executor};


my $cb = sub {
    print shift;
};
my $on_finished = sub {

};

#print "Should wait for connection to be established";
if ($return_url) {
    my $connected = AnyEvent->condvar();

    my $uri = URI->new($return_url);

    my ( $host, $port, $path ) = ( $uri->host(), $uri->port(), $uri->path() );

    my $handle;
    $handle = AnyEvent::Handle->new(
        timeout    => 30,
        connect    => [ $host, "http=$port" ],
        keepalive  => 1,
        autocork   => 1,
        on_error   => sub {
            my ( $hdl, $fatal, $message ) = @_;

            warn "Error happened (fatal: $fatal): $message\n";
            # die "Can't connect to '$return_url'";
        },
        on_connect => sub {
            my ( $fh ) = @_;

            # Send headers
            $handle->push_write(
                "POST $path HTTP/1.1\n"
                    . "Host: $host:$port\n"
                    . "User-Agent: FlashChecker-Executor\n"
                    . "Connection: keep-alive\n"
                    . "Content-Type: text/plain\n\nasdasda"
            );

            # $cb = sub {
            #     my $line = shift;
            #     print $line;
            # $handle->push_write($line);
            # };

            $connected->send();
        },
    );

    $on_finished = sub {
        $handle->push_shutdown();
        undef $handle;
    };

    $connected->recv();
}

my $done2 = AnyEvent->condvar;
my $pid2 = fork or do {
    open(my $fh, '-|', $command) or do {
        $cb->("Failed to run command: $@\n");
        POSIX::_exit(1);
    };

    while (<$fh>) {
        $cb->($_);
    }

    $on_finished->();

    POSIX::_exit(0);
};
#
# my $w = AnyEvent->child(
#     pid => $pid2,
#     cb  => sub {
#         my ( $pid2, $status ) = @_;
#         print "Callback\n";
#         print "pid $pid2 exited with status $status";
#         $done2->send;
#     },
# );
#
# $done2->recv;

exit 0;