package FlashChecker::UI::Mojo::Clients;
use strict;
use warnings FATAL => 'all';

use Mojo::IOLoop;
use Mojo::Transaction::WebSocket;

use Data::Dumper;
use Cpanel::JSON::XS qw/encode_json/;
use Digest::SHA1;
use Carp;

use Mojo::Log;
my $log = Mojo::Log->new;
my $Json = Cpanel::JSON::XS::->new->utf8(0)->pretty(0);

my %delivery_confirm = ();
my $msg_num = 1;

sub new {
    my ( $class, %params ) = @_;
    my $self = {
        %params,
        clients => {}
    };

    $self->{ping_period} = $params{config}->{Websocket}->{PingPeriod} || 30;

    bless $self, $class;
    return $self;
}

#@returns Mojo::EventEmitter
sub events {return shift->{events}}

sub on_message {
    my ( $self, $cl_id, $mojo_, $hash ) = @_;

    if (! $self->get($cl_id)) {
        $log->warn("Received message from an unregistered client $cl_id");
        return;
    }

    if (! $hash->{type}) {
        $log->warn("Received message without type. Ignoring:" . Dumper $hash);
        return;
    }

    # Technical handlers
    if ($hash->{type} eq 'confirm' && $hash->{seq}) {
        my $confirm_action = $delivery_confirm{$hash->{seq}}->{confirm_sub};
        delete $delivery_confirm{$hash->{seq}};

        return unless $confirm_action;

        if (ref $confirm_action eq 'CODE') {
            $confirm_action->($hash);
        }
    }
    elsif ($hash->{type} eq 'disconnect') {
        $self->disconnected($cl_id);
    }
    elsif ($hash->{type} eq 'ping') {
        $self->send_message($cl_id, { type => 'pong' })
    }
    elsif ($hash->{type} eq 'pong') {
        if (! $hash->{seq}) {
            confess "Received pong without 'seq'.";
        }
        delete $delivery_confirm{$hash->{seq}};
    }
    else {
        # This is not a technical message
        return 1;
    }

    return 0;
}

sub config {
    my ( $self, $config ) = @_;

    if (defined $config) {
        $self->{ping_period} = $config->{Websocket}->{PingPeriod} || 30;

        if ($self->{pinger}) {
            # Should restart previous pinger
            delete $self->{pinger};
            $self->_continious_ping();
        }
    }

    return $config;
}

sub add {
    my ( $self, $mojo, $tx ) = @_;

    my $id = $tx->connection();
    # my $prev = $mojo->cookie('tx');
    #
    # if ($self->{clients}->{$prev}) {
    #     # Old client with new connection
    #     $self->disconnected($prev);
    # }

    if (! $self->{clients}->{$id}) {
        # New client
        # $mojo->cookie('tx' => $id);
        $self->{clients}->{$id} = $tx;
    }

    return $id;
}

sub get {
    my ( $self, $cl_id ) = @_;
    if ($cl_id =~ /Mojo/) {
        confess "Code uses old ID";
    };

    return $self->{clients}->{$cl_id};
}

sub count {
    my ( $self ) = @_;
    return scalar keys %{$self->{clients}};
}

sub get_all {
    my ( $self ) = @_;
    return keys %{$self->{clients}};
}

sub disconnected {
    my ( $self, $cl ) = @_;
    $log->debug("Client disconnected $cl.");

    unless (exists $self->{clients}->{$cl}) {
        $log->debug("Disconnecting a client that was not registered: $cl");
        return 0;
    }

    # Remove all confirmations for disconnected client
    delete @delivery_confirm{@{_undelivered_messages_for($cl)}};

    delete $self->{clients}->{$cl};
    return 1;
}

sub send_message {
    my ( $self, $cl_id, $msg, $confirm_sub ) = @_;
    return unless $cl_id;

    if ($cl_id eq 'ALL') {
        $self->notify_all($msg, $confirm_sub);
    }

    $msg->{seq} = $msg_num ++;
    $delivery_confirm{$msg->{seq}} = {
        type        => $msg->{type},
        ttl         => $msg->{ttl},
        ts          => $msg->{ts},
        client      => $cl_id,
        confirm_sub => $confirm_sub,
    };

    my $json;
    eval {
        $json = $Json->encode($msg);
        1;
    } or do {
        print "to JSON:" . Dumper $msg;
        confess "Failed to encode json : $@";
        return;
    };

    eval {
        my Mojo::Transaction::WebSocket $cl = $self->get($cl_id);
        $log->debug("Sending message($msg->{seq}) to cl $cl_id:\n$json\n") unless $msg->{type} eq 'ping';
        $cl->send($json);
    } or do {
        confess "Failed to send message: $@\n";
        $self->disconnected($cl_id);
        return;
    };
    return 1;
}

sub notify_all {
    my ( $self, $event, $cb ) = @_;

    for ($self->get_all()) {
        $self->send_message($_, $event, $cb);
    }

    return 1;
}

sub _continious_ping {
    my ( $self ) = @_;

    # Check for failed ping
    for my $seq_id (keys %delivery_confirm) {
        next if (! exists $delivery_confirm{$seq_id} || ! $delivery_confirm{$seq_id}->{type});
        next if $delivery_confirm{$seq_id}->{type} ne 'ping';

        my $msg = $delivery_confirm{$seq_id};
        if (time() - $msg->{ts} >= $msg->{ttl}) {
            $log->info("Client disconnected by timeout $msg->{client}");
            $self->disconnected($msg->{client});
        }
    }

    $self->{pinger} = Mojo::IOLoop->timer($self->{ping_period} => sub {
        $self->notify_all({ type => 'ping', ts => => time(), ttl => 3 * $self->{ping_period} });
        $self->_continious_ping();
    });
}

sub _undelivered_messages_for {
    my ( $cl_id ) = @_;
    my @seq_ids = grep {
        $delivery_confirm{$_}->{client} eq $cl_id
    } keys %delivery_confirm;

    return \@seq_ids;
}

END {
    print "UNDELIVERED: " . Dumper \%delivery_confirm;
}


1;