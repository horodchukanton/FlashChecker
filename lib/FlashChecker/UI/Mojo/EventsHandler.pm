package FlashChecker::UI::Mojo::EventsHandler;
use strict;
use warnings FATAL => 'all';

use Data::Dumper;
use Carp;

use Mojo::IOLoop;
use Mojo::EventEmitter;
use Mojo::Log;

use USB::Listener;
use FlashChecker::UI::Mojo::Clients;
use FlashChecker::UI::Mojo::Workers;

my $log = Mojo::Log->new;
my $event_emitter = Mojo::EventEmitter->new();

sub new {
    my ($class, $config) = @_;

    my $self = {
        clients  => FlashChecker::UI::Mojo::Clients->new(
            config => $config,
            events => $event_emitter
        ),
        workers  => FlashChecker::UI::Mojo::Workers->new(
            config => $config,
            events => $event_emitter
        ),
        listener => USB::Listener->new(config => $config),
        config   => $config
    };
    bless $self, $class;
    return $self;
}

sub start {
    my ($self, $queue) = @_;

    my $config = $self->{config};

    $self->{period} = $config->{USB}->{Poll} || 3;
    $self->{actions} = $config->{Actions};

    $self->init_events();
    $self->check_queue($queue);
    $self->clients->_continious_ping();
}

#@returns FlashChecker::UI::Mojo::Clients
sub clients {
    return shift->{clients};
}

#@returns FlashChecker::UI::Mojo::Workers
sub workers {
    return shift->{workers};
}

#@returns USB::Listener
sub listener {
    my ($self) = @_;
    return $self->{listener};
}

sub init_events {
    my ($self) = @_;
    $event_emitter->on(
        'worker_event'      => sub {
            my ($emitter, $token, $cl_id, $event, $type) = @_;
            $self->clients->send_message($cl_id, {
                type  => $type || 'worker_event',
                token => $token,
                event => $event
            });
        },
        'message_to_worker' => sub {
            my ($emitter, $token, $cl_id, $event, $type) = @_;

            # For now, I can't see anything useful, except 'action_cancelled',
            # but we can send anything else

            $self->clients->send_message($cl_id, {
                type  => $type || 'worker_message',
                token => $token,
                event => $event
            });
        }
    );
}

sub websocket_message {
    my ($self, $mojo) = @_;

    my $cl_id = $self->clients->add($mojo, $mojo->tx);

    $mojo->on(
        json   => sub {
            my $clients = $self->clients;

            # Passing technical messages
            my $operation_message = $clients->on_message($cl_id, @_);
            return if (!$operation_message);

            my (undef, $hash) = @_;
            $self->_on_command_message($cl_id, $hash);
        },
        finish => sub {$self->clients->disconnected($cl_id)}
    );

    return 1;
}

sub _on_command_message {
    my ($self, $cl_id, $msg) = @_;

    if ('request_list' eq $msg->{type}) {
        my $list = $self->listener->get_list_of_devices();
        $self->_inflate_device_info($_) for @$list;

        $self->clients->send_message($cl_id, {
            type    => 'list',
            devices => $list
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
    elsif ('action_request' eq $msg->{type}) {
        my $response = $self->_on_operation_request($cl_id, $msg->{action}, $msg->{device_id});
        $response->{request_num} = $msg->{request_num};
        $self->clients->send_message($cl_id, $response);
    }
    elsif ('action_info_request' eq $msg->{type}) {
        my ($token, $offset) = ($msg->{token}, $msg->{offset});
        if (my $info = $self->workers->has_info($token, $offset || 0)) {
            $self->clients->send_message($cl_id, $info);
        }
    }
    elsif ('action_operation_seen' eq $msg->{type}) {
        $self->workers->client_seen_operations($cl_id, $msg->{token});
    }
    elsif ('action_all_operations_seen' eq $msg->{type}) {
        $self->workers->client_seen_operations($cl_id);
    }
    elsif ('action_cancel_operation' eq $msg->{type}) {
        my $token = $msg->{token};
        $self->workers->cancel_operation($token);
    }
    elsif ($msg->{type} =~ /^worker_/) {
        eval {
            $self->workers->worker_message($msg, $cl_id);
        } or do {
            $log->error("Failed to process the worker message: $@");
        }
    }
    else {
        $log->warn("Unregistered message type: $msg->{type}");
    }
};

sub _on_operation_request {
    my ($self, $client_id, $action, $device_id) = @_;

    unless ($device_id) {
        $log->warn("No device id to return info");
        return _error_message("No device id to return info");
    }

    my $actions = $self->get_actions($device_id);

    if (!grep {$_ eq $action} @$actions) {
        $log->warn("Request for unsupported action: '$action'");
        return _error_message("Request for an unsupported action: '$action'");
    }
    if (!grep {$_ eq $action} keys %{$self->{actions}}) {
        $log->warn("Request for unimplemented action: '$action'");
        return _error_message("Request for an unsupported action: '$action'");
    }

    my $device = $self->listener->get_device_info($device_id);

    my $operation_token = $self->workers()->start_operation({
        action           => $action,
        device           => $device,
        device_id        => $device_id,
        command_template => $self->{actions}->{$action},
        client_id        => $client_id,
        params           => {
            DeviceID => $device_id
        }
    });

    if (ref $operation_token) {
        $log->warn("Failed to start an operation:", Dumper($operation_token));
        return _error_message($operation_token->{message});
    }

    return {
        type  => 'action_accepted',
        token => $operation_token
    };
}

sub executor_response {
    my ($self, $token, $response) = @_;

    print "CLIENT: $token\n SENT: $response\n";
}


sub get_actions {
    my ($self, $device_id) = @_;

    my %all_actions = %{$self->{actions}};

    my $device = $self->listener->get_device_info($device_id);

    # 'Check' requires device to be mounted
    if (!$device->{VolumeSerialNumber}) {
        delete $all_actions{Check};
    }

    return [ sort keys %all_actions ];
}

sub check_queue {
    my ($self, $queue) = @_;
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
    my ($self, $queue) = @_;
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
        elsif ($event->{type} eq 'changed') {
            return unless $event->{id};
            my $device = $self->_inflate_device_info($event->{device});
            $self->clients->notify_all({
                type   => 'changed',
                id     => $event->{id},
                device => $device
            });
        }
        elsif ($event->{type} eq 'connected') {
            return unless $event->{id};
            $self->new_device_connected({ %{$event->{device}} });
        }
        else {
            $log->debug("Unknown event: " . Dumper($event) . "");
        };
    }

    return 1;
}

sub new_device_connected {
    my ($self, $device_info) = @_;

    $self->_inflate_device_info($device_info);

    $self->clients->notify_all({
        type   => 'connected',
        id     => $device_info->{id},
        device => $device_info
    });

    return 1;
}

sub _inflate_device_info {
    my ($self, $device_info) = @_;
    my $id = $device_info->{id};

    $device_info->{Actions} = $self->get_actions($id);

    return $device_info;
}

sub _error_message {
    my ($message) = @_;
    return {
        type    => 'error',
        message => $message
    }
}

1;