package FlashChecker::UI::Mojo::EventsHandler;
use strict;
use warnings FATAL => 'all';

use Mojo::WebSocket;
use Mojo::IOLoop;
use Data::Dumper;
use Cpanel::JSON::XS qw/encode_json/;
use Carp;

my %delivery_confirm = ();
my $msg_num = 1;

sub new {
    my ( $class, %params ) = @_;
    my $self = {
        clients     => [],
        period      => $params{period} || 3,
        ping_period => 30,
        %params
    };
    bless $self, $class;
    return $self;
}

sub start {
    my ( $self, $queue ) = @_;
    $self->check_queue($queue);
    $self->continious_ping();
}

sub new_client {
    my ( $self, $mojo ) = @_;

    my $transaction = $mojo->tx;
    print "New Client is $transaction \n";;

    push(@{$self->{clients}}, $transaction);

    $mojo->on(json => sub {
        my ( $mojo_, $hash ) = @_;

        print "INSIDE: $mojo_\n";

        if ($hash->{seq} && $hash->{type} eq 'confirm') {
            print "Got confirm for $hash->{seq}\n";
            delete $delivery_confirm{$hash->{seq}};
        }
        else {
            print "Received message: " . Dumper $hash;
        }

    });

    $mojo->on(finish => sub {
        $self->client_disconnected($transaction);
    });

    $self->continious_ping($transaction);

    #
    # $self->send_message($cl, { type => 'hi there' });
}

sub continious_ping {
    my ( $self ) = @_;

    $self->{pinger} = Mojo::IOLoop->timer($self->{ping_period} => sub {
        $self->notify_clients({ type => 'ping' });
        $self->continious_ping();
    });
}

sub client_disconnected {
    my ( $self, $cl ) = @_;

    print "Client disconected $cl.\n";

    # Find and splice the client that should be disconnected
    for (my $i = 0; $i < scalar(@{$self->{clients}}); $i ++) {
        if ($self->{clients}->[$i] eq $cl) {
            splice(@{$self->{clients}}, $i, 1);
        }
    }
}

sub check_queue {
    my ( $self, $queue ) = @_;

    $self->{checker} = Mojo::IOLoop->timer($self->{period} => sub {
        eval {
            if ($queue->pending()) {
                $self->process_events($queue);
            }
            1;
        } or do {
            print "Failed to check the queue: $@\n";
        };

        # Alwaaays
        $self->check_queue($queue);
    });
}

sub process_events {
    my ( $self, $queue ) = @_;
    print "Got events\n";
    print "We have " . ( scalar @{$self->{clients}} ) . " client(s).\n";

    # Don't want to miss the events when nobody is connected
    return 1 unless scalar @{$self->{clients}};

    print "Going to notify\n";

    while (my $event = $queue->dequeue()) {

        print "EVENT: " . Dumper $event;

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
            # Need to gather info about the device,
            $self->notify_clients({
                type => 'connected',
                id   => $event->{id}
            });
        }
        else {
            print "Unknown event: " . Dumper($event) . "\n";
        };
    }
    print "Queue finished.\n";
    return 1;
}

sub notify_clients {
    my ( $self, $event ) = @_;

    for (@{$self->{clients}}) {
        $self->send_message($_, $event);
    }

    return 1;
}

sub send_message {
    my ( $self, $tx, $msg ) = @_;

    $msg->{seq} = $msg_num ++;

    $delivery_confirm{$msg->{seq}} = $tx;

    my $json;
    eval {
        $json = Cpanel::JSON::XS::encode_json($msg);
        1;
    } or do {
        print Dumper $msg;
        confess "Failed to encode json : $@";
        return;
    };

    eval {
        print "Sending message($msg->{seq}) to cl $tx:\n$json\n\n";
        $tx->send($json);
    } or do {
        print "Failed to send message: $@\n";
        $self->client_disconnected($tx);
        return;
    };

    return 1;
}

END {
    print "UNDELIVERED: " . Dumper \%delivery_confirm;
}


1;