package FlashChecker::UI::Mojo::EventsHandler;
use strict;
use warnings FATAL => 'all';

use Data::Dumper;
use Carp;

use Mojo::IOLoop;
use Mojo::Log;

use USB::Listener;
use FlashChecker::UI::Mojo::Clients;

my $log = Mojo::Log->new;

sub new {
    my ( $class ) = @_;
    my $self = {
        clients  => FlashChecker::UI::Mojo::Clients->new(),
        listener => USB::Listener->new()
    };
    bless $self, $class;
    return $self;
}

sub start {
    my ( $self, %params ) = @_;

    my $config = $params{config};

    $self->{period} = $config->{USB}->{Poll} || 3;
    $self->{actions} = $config->{Actions};
    $self->{params} = \%params;

    $self->check_queue($params{queue});

    $self->clients->config($config);
    $self->clients->_continious_ping();
}

#@returns FlashChecker::UI::Mojo::Clients
sub clients {
    my ( $self ) = @_;
    return $self->{clients};
}

#@returns USB::Listener
sub listener {
    my ( $self ) = @_;
    return $self->{listener};
}

sub websocket_message {
    my ( $self, $mojo ) = @_;

    my $cl_id = $self->clients->add($mojo, $mojo->tx);

    $mojo->on(
        json   => sub {
            my $clients = $self->clients;

            # Passing technical messages
            my $operation_message = $clients->on_message($cl_id, @_);
            return if (! $operation_message);

            my ( undef, $hash ) = @_;
            $self->_on_command_message($cl_id, $hash);
        },
        finish => sub {$self->clients->disconnected($cl_id)}
    );

    return 1;
}

sub _on_command_message {
    my ( $self, $cl_id, $msg ) = @_;

    if ('request_list' eq $msg->{type}) {

        my $list = $self->listener->get_list_of_devices();
        my @with_actions = map {$_->{Actions} = $self->get_actions($_->{id});
            $_} @$list;

        $self->clients->send_message($cl_id, {
            type    => 'list',
            devices => \@with_actions
        });
    }
    elsif ('get_actions' eq $msg->{type}) {
        $self->clients->send_message($cl_id, {
            type    => 'list',
            devices => $self->get_actions($msg->{deviceID})
        });
    }
    elsif ('request_info' eq $msg->{type}) {
        unless ($msg->{device_id}) {
            $log->warn("No device id to return info");
            return;
        }
        $self->clients->send_message($cl_id, {
            type    => 'device',
            devices => $self->listener->get_device_info($msg->{device_id})
        });
    }
}

sub executor_response {
    my ( $self, $token, $response ) = @_;

    print "CLIENT: $token\n SENT: $response\n";
}


sub get_actions {
    my ( $self, $device_id ) = @_;

    my %all_actions = %{$self->{actions}};

    my $device = $self->listener->get_device_info($device_id);

    # 'Check' requires device to be mounted
    if (! $device->{VolumeSerialNumber}) {
        delete $all_actions{Check};
    }

    return [ sort keys %all_actions ];
}

sub check_queue {
    my ( $self, $queue ) = @_;
    # $log->debug("Checking the queue. ");

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
    $log->debug("Processing, we have " . $self->clients->count . " client(s).");

    while (my $event = $queue->dequeue_nb()) {
        if ($event->{type} eq 'start') {
            $self->clients->notify_all({
                type => 'restarted'
            });
        }
        elsif ($event->{type} eq 'removed') {
            return unless $event->{id};
            $self->clients->notify_all({
                type => 'removed',
                id   => $event->{id}
            });
        }
        elsif ($event->{type} eq 'connected') {
            return unless $event->{id};
            $self->new_device_connected($event->{device});
        }
        else {
            $log->debug("Unknown event: " . Dumper($event) . "");
        };
    }

    return 1;
}

sub new_device_connected {
    my ( $self, $device_info ) = @_;

    $self->clients->notify_all({
        type   => 'connected',
        id     => $device_info->{id},
        device => $device_info
    });

    return 1;
}

1;