package FlashChecker::UI::Mojo::Workers;
use strict;
use warnings FATAL => 'all';

use Digest::MD5 qw/md5_hex/;
use Data::Dumper;

use Mojo::Log;
use File::Spec;

my $log = Mojo::Log->new();

# One operation per device
my %running = ();

sub new {
    my ( $class, %params ) = @_;
    my $self = { %params };
    bless $self, $class;
    return $self;
}

#@returns Mojo::EventEmitter
sub events {return shift->{events}}

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

    if (exists $running{$token}) {
        return {
            message => "Action '$params->{action}' is already running for '$params->{device_id}'" };
    }

    my $return_url = $self->build_return_url($token);
    my $command = render_command_template($params->{command_template}, {
        Time => time(),
        %{$params->{params} ? $params->{params} : {}}
    });

    $command =~ s/"/\\"/g;

    my $executor_path = File::Spec->catfile(File::Spec->catpath('.\\', 'bin'), 'executor.pl');
    my $executor_cmd = render_command_template(
        $executor_path . q{ --command "{{ Command }}" --returnUrl "{{ ReturnURL }}" --token "{{ Token }}"},
        {
            Command   => $command,
            ReturnURL => $return_url,
            Token     => $token
        }
    );

    $log->info("Before running command: " . $executor_cmd);

    eval {
        my $pid = $self->spawn_worker($executor_cmd);
        $running{$token} = { client => $params->{client_id}, pid => $pid, info => [] };
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

    if ($^O eq 'MSWin32') {
        return system(1, $command);
    }
    else {
        my $pid = fork();
        if ($pid == 0) {
            # Child
            exit system($command);
        }

        return $pid;
    }
}

sub worker_message {
    my ( $self, $message ) = @_;

    my $message_type = $message->{type};
    my $worker_token = $message->{token};

    if (! exists $running{$worker_token}) {
        $log->warn('UNREGISTERED WORKER TOKEN');
        $self->emit_for_token($worker_token, 'ALL', $message);
        return;
    }

    my $client_id = $running{$worker_token}->{client};

    if ($message_type eq 'worker_action_started') {
        $log->info("Worker said that he started an operation");
        $self->emit_for_token($worker_token, $message);
    }
    elsif ($message_type eq 'worker_child_running') {
        $log->info("Worker is running");
        $self->emit_for_token($worker_token, $message);
    }
    elsif ($message_type eq 'worker_child_finished') {
        $log->info("Worker has finished, can now clear running token");
        $self->finished_operation($worker_token);
        $self->emit_for_token($worker_token, $message);
    }
    elsif ($message_type eq 'worker_output') {
        $log->info("Worker returns output: '$message->{content}'");
        $self->output_updated($worker_token, $message->{content});
        $self->emit_for_token($worker_token, $message);
    }
    elsif ($message_type eq 'worker_me_crashed') {
        $log->info("Worker crashed. Why Windows, WHY???");
        $self->finished_operation($worker_token, 1);
        $self->emit_for_token($worker_token, $message);
    }
    else {
        print "Worker message:" . Dumper $message;
    }

}

sub output_updated {
    my ( $self, $token, $content ) = @_;
    # Should add it to info
    push @{$running{$token}->{info}}, $content;
}

sub finished_operation {
    my ( $self, $token, $was_error ) = @_;

    push @{$running{$token}->{info}}, { type => $was_error ? 'ERROR' : 'FINISHED' };

    $running{$token}->{on_request_cb} = sub {
        delete $running{$token};
    };
}

sub cancel_operation {
    # TODO: Get a channel to worker,
    # send the 'action_cancelled' request
    return 1;

}

sub has_info {
    my ( $self, $token, $offset ) = @_;

    my $job = $running{$token};

    my $ret;

    if (! exists $job->{info}) {
        return {
            type  => 'operation_no_info_available',
            token => $token
        }
    }

    my $last_index = scalar(@{$job->{info}}) - 1;
    if ($offset > $last_index) {
        $ret = {
            type       => 'operation_wrong_offset',
            token      => $token,
            last_index => $last_index
        }
    }
    else {
        # From index to the end
        $ret = {
            type       => 'operation_new_content',
            token      => $token,
            info       => [ @{$job->{info}}[$offset ... $last_index] ],
            last_index => $last_index
        }
    }

    if (exists $job->{on_request_cb}) {
        &{$job->{on_request_cb}}();
    }

    return $ret;
}

sub who_started {
    my ( $self, $token ) = @_;
    my $job = $running{$token};
    if (! $job) {
        return 0;
    }
    return $job->{client_id};
}

sub build_return_url {
    my ( $self ) = @_;

    my $host = $self->{config}->{Listen}->{Address} || '127.0.0.1';
    my $port = $self->{config}->{Listen}->{Port} || '8080';

    if ($host eq '0.0.0.0' || $host eq '*') {
        $host = '127.0.0.1'
    }

    return "ws://$host:$port/ws";
}

sub render_command_template {
    my ( $cmd_template, $params ) = @_;

    for (keys %$params) {
        $cmd_template =~ s/\{\{ +$_ +\}\}/$params->{$_}/g;
    }

    return $cmd_template;
}

sub emit_for_token {
    my ( $self, $token, $event ) = @_;
    my $client = $running{$token}->{client};

    $self->events->emit('worker_event', $token, $client, $event);
}

1;