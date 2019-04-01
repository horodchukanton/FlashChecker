package FlashChecker::UI::Mojo::EventsHandler;
use strict;
use warnings FATAL => 'all';

use Mojo::WebSocket;
use Mojo::IOLoop;
use Mojo::Transaction::WebSocket;

use Data::Dumper;
use Cpanel::JSON::XS qw/encode_json/;
use Carp;

use Mojo::Log;
my $log = Mojo::Log->new;

my %delivery_confirm = ();
my $msg_num = 1;

sub new {
    my ( $class ) = @_;
    my $self = {
        clients => {}
    };
    bless $self, $class;
    return $self;
}

sub start {
    my ( $self, %params ) = @_;

    my $config = $params{config};

    $self->{period} = $config->{USB}->{Poll} || 3;
    $self->{ping_period} = $config->{Websocket}->{PingPeriod} || 30;

    $self->{params} = \%params;

    $self->check_queue($params{queue});
    $self->continious_ping();
}

sub new_client {
    my ( $self, $mojo ) = @_;

    my $transaction = $mojo->tx;
    $log->debug("New Client is $transaction");

    $mojo->on(
        json   => sub {
            my ( $mojo_, $hash ) = @_;
            if ($hash->{seq} && $hash->{type} eq 'confirm') {
                my $confirm_action = $delivery_confirm{$hash->{seq}}->{confirm_sub};
                return unless $confirm_action;

                if (ref $confirm_action eq 'CODE') {
                    $confirm_action->($hash);
                }

                delete $delivery_confirm{$hash->{seq}};
            }
        },
        finish => sub {
            $self->client_disconnected($transaction);
        }
    );

    $self->{clients}->{$transaction} = $transaction;

    return 1;
}

sub continious_ping {
    my ( $self ) = @_;

    $log->debug("every $self->{ping_period}. PING: " . scalar(keys %{$self->{clients}}) . "");

    $self->{pinger} = Mojo::IOLoop->timer($self->{ping_period} => sub {
        $self->notify_clients({ type => 'ping' }, sub {
            $log->debug("Ping was confirmed");
        });
        $self->continious_ping();
    });
}

sub client_disconnected {
    my ( $self, $cl ) = @_;
    $log->debug("Client disconnected $cl.");

    unless (exists $self->{clients}->{$cl}) {
        $log->debug("Disconnecting a client that was not registered: $cl");
        return 0;
    }

    delete $self->{clients}->{$cl};
    return 1;
}

sub check_queue {
    my ( $self, $queue ) = @_;
    $log->debug("Checking the queue. ");

    $self->{checker} = Mojo::IOLoop->timer($self->{period} => sub {
        eval {
            if ($queue->pending()) {
                $self->process_events($queue);
            }
            1;
        } or do {
            $log->debug("Failed to check the queue: $@");
        };

        # Alwaaays
        $self->check_queue($queue);
    });
}

sub process_events {
    my ( $self, $queue ) = @_;
    $log->debug("Processing, we have " . ( scalar keys %{$self->{clients}} ) . " client(s).");

    while (my $event = $queue->dequeue_nb()) {
        if ($event->{type} eq 'start') {
            $self->notify_clients({
                type => 'restarted'
            });
        }
        elsif ($event->{type} eq 'removed') {
            $self->notify_clients({
                type => 'removed',
                id   => $event->{id}
            });
        }
        elsif ($event->{type} eq 'connected') {
            # TODO: Need to gather info about the device,
            $self->notify_clients({
                type => 'connected',
                id   => $event->{id}
            });
        }
        else {
            $log->debug("Unknown event: " . Dumper($event) . "");
        };
    }

    return 1;
}

sub notify_clients {
    my ( $self, $event, $cb ) = @_;

    $log->debug("Notify");
    for (keys %{$self->{clients}}) {
        $self->send_message($self->{clients}->{$_}, $event, $cb);
    }

    return 1;
}

sub send_message {
    my ( $self, $tx, $msg, $confirm_sub ) = @_;

    $msg->{seq} = $msg_num ++;
    $delivery_confirm{$msg->{seq}} = {
        client      => $tx,
        confirm_sub => $confirm_sub
    };

    my $json;
    eval {
        $json = Cpanel::JSON::XS::encode_json($msg);
        1;
    } or do {
        print "to JSON:" . Dumper $msg;
        confess "Failed to encode json : $@";
        return;
    };

    eval {
        $log->debug("Sending message($msg->{seq}) to cl $tx:\n$json\n");
        $tx->send($json);
    } or do {
        confess "Failed to send message: $@\n";
        $self->client_disconnected($tx);
        return;
    };
    return 1;
}

END {
    print "UNDELIVERED: " . Dumper \%delivery_confirm;
}


1;