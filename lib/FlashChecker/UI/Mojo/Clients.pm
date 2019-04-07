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

my %delivery_confirm = ();
my $msg_num = 1;

sub new {
    my ( $class, %params ) = @_;
    my $self = { clients => {} };
    bless $self, $class;
    return $self;
}

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
        delete $delivery_confirm{$hash->{seq}};

        my $confirm_action = $delivery_confirm{$hash->{seq}}->{confirm_sub};
        return unless $confirm_action;

        if (ref $confirm_action eq 'CODE') {
            $confirm_action->($hash);
        }
    }
    elsif ($hash->{type} eq 'disconnect') {
        $self->disconnected($cl_id);
        $mojo_->finish(1000);
        $log->debug('Client ' . $cl_id . ' disconnected');
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
    my ( $self, $tx ) = @_;
    my $id = Digest::SHA1->sha1_base64('' . $tx);

    if (! $self->{clients}->{$id}) {
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

    delete $self->{clients}->{$cl};
    return 1;
}

sub send_message {
    my ( $self, $cl_id, $msg, $confirm_sub ) = @_;

    $msg->{seq} = $msg_num ++;
    $delivery_confirm{$msg->{seq}} = {
        client      => $cl_id,
        confirm_sub => $confirm_sub
    };

    my $json;
    eval {
        $json = encode_json($msg);
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

    # $log->debug("every $self->{ping_period}. PING: " . $self->count() . "");

    $self->{pinger} = Mojo::IOLoop->timer($self->{ping_period} => sub {
        $self->notify_all({ type => 'ping' });
        $self->_continious_ping();
    });
}

END {
    print "UNDELIVERED: " . Dumper \%delivery_confirm;
}


1;