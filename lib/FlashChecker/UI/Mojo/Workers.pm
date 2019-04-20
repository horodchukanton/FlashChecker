package FlashChecker::UI::Mojo::Workers;
use strict;
use warnings FATAL => 'all';

use Digest::MD5 qw/md5_hex/;
use AnyEvent::Impl::Perl;

use Data::Dumper;
use Mojo::Log;
my $log = Mojo::Log->new();

# One operation per device
my %running = ();

use Mojo::Server::Daemon;
use AnyEvent::Handle;

our $WORKER_PORT = 8081;


sub new {
    my ( $class, %params ) = @_;
    my $self = { %params };
    bless $self, $class;
    return $self;
}

=head2 start_operation

  my $operation_token = $self->workers()->start_operation({
      action           => $action,
      device           => $device,
      device_id        => $device_id,
      command_template => "FORMAT {{ DeviceID }}",
      return_url       => 'http://localhost:8080/command/token',
      params           => {
          DeviceID => $device_id
      }
  });

=cut
sub start_operation {
    my ( $self, $params ) = @_;

    my $token = md5_hex($params->{device_id} . $params->{action}) . '==';

    if ($running{$token}) {
        return {
            message => "Action '$params->{action}' is already running for '$params->{device_id}'" };
    }

    my $return_url = $self->build_return_url($token);
    my $command = render_command_template($params->{command_template}, {
        Time => time(),
        %{$params->{params} ? $params->{params} : {}}
    });

    $command =~ s/"/\\"/g;

    my $executor_cmd = render_command_template(
        q{.\bin\executor.pl --command "{{ Command }}" --returnUrl "{{ ReturnURL }}"},
        {
            Command   => $command,
            ReturnURL => $return_url
        }
    );

    $log->info("Before running command: " . $executor_cmd);

    eval {
        my $pid = $self->spawn_worker($executor_cmd);
        $running{$token} = $pid;
        1;
    }
        or do {
        return {
            message => "Failed to start operation: $@"
        }
    };

    return $token;
}

sub spawn_worker {
    my ( $self, $command ) = @_;
    return system(1, $command);
}

sub worker_message {
    my ( $self, $message ) = @_;

    if ($message->{type} eq 'worker_action_started') {
        $log->info("Worker said that he started an operation");
    }
    else {
        print "Worker message:" . Dumper $message;
    }

}

sub has_info {
    my ( $self, $token ) = @_;
    return {
        "type"    => "info",
        "message" => "Hi,there",
        "token"   => $token
    };
}

sub build_return_url {
    my ( $self, $token ) = @_;

    my $host = $self->{config}->{Listen}->{Address} || '127.0.0.1';
    my $port = $self->{config}->{Listen}->{Port} || '8080';

    return "http://$host:$port/command/$token";
}

sub render_command_template {
    my ( $cmd_template, $params ) = @_;

    for (keys %$params) {
        $cmd_template =~ s/\{\{ +$_ +\}\}/$params->{$_}/g;
    }

    return $cmd_template;
}


1;