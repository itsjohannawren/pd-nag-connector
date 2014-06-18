#!/usr/bin/env perl

use warnings;
use strict;

use CGI;
use JSON;
use LWP::UserAgent;

# =============================================================================

my $CONFIG = {
	'command_file' => '/var/lib/nagios3/rw/nagios.cmd', # External commands file
	'status_file' => '/var/cache/nagios3/status.dat', # Status data file
};

# =============================================================================

sub problemToHostService {
	my ($problemID) = @_;
	my ($line, $result, $type, $section, $problems);

	$result = {};
	$problems = {};

	if (! open (STATUS, '<', $CONFIG->{'status_file'})) {
		return (undef, $!);
	}

	while ($line = <STATUS>) {
		$line =~ s/(\r\n|\n\r|\n|\r)//ms;
		$line =~ s/#.*//;
		$line =~ s/^\s+//;
		$line =~ s/\s+$//;

		if ($line =~ /^([a-z0-9_-]+)\s*\{$/i) {
			$type = lc ($1);
			#if (! defined ($result->{$type})) {
			#	$result->{$type} = {};
			#}
			$section = {};

		} elsif ($line =~ /^\}$/) {
			if ($type eq 'info') {
				#$result->{$type} = $section;

			} elsif ($type eq 'programstatus') {
				#$result->{$type} = $section;

			} elsif ($type eq 'hoststatus') {
				#$result->{$type}->{$section->{'host_name'}} = $section;

				if (defined ($section->{'current_problem_id'}) && $section->{'current_problem_id'}) {
					$problems->{$section->{'current_problem_id'} . ''} = {
						'host' => $section->{'host_name'},
					};
				}
				if (defined ($section->{'last_problem_id'}) && $section->{'last_problem_id'}) {
					$problems->{$section->{'last_problem_id'} . ''} = {
						'host' => $section->{'host_name'},
					};
				}

			} elsif ($type eq 'servicestatus') {
				#if (! defined ($result->{$type}->{$section->{'host_name'}})) {
				#	$result->{$type}->{$section->{'host_name'}} = {};
				#}
				#$result->{$type}->{$section->{'host_name'}}->{$section->{'service_description'}} = $section;

				if (defined ($section->{'current_problem_id'}) && $section->{'current_problem_id'}) {
					$problems->{$section->{'current_problem_id'} . ''} = {
						'host' => $section->{'host_name'},
						'service' => $section->{'service_description'},
					};
				}
				if (defined ($section->{'last_problem_id'}) && $section->{'last_problem_id'}) {
					$problems->{$section->{'last_problem_id'} . ''} = {
						'host' => $section->{'host_name'},
						'service' => $section->{'service_description'},
					};
				}

			} elsif ($type eq 'contactstatus') {
				#$result->{$type}->{$section->{'contact_name'}} = $section;

			} elsif ($type eq 'hostcomment') {
				#$result->{$type}->{$section->{'host_name'}} = $section;

			} elsif ($type eq 'servicecomment') {
				#if (! defined ($result->{$type}->{$section->{'host_name'}})) {
				#	$result->{$type}->{$section->{'host_name'}} = {};
				#}
				#$result->{$type}->{$section->{'host_name'}}->{$section->{'service_description'}} = $section;
			}

			$section = {};

		} elsif ($line =~ /^([a-z0-9_-]+)\s*=\s*(\S.*)$/) {
			# Value
			$section->{lc ($1)} = $2;
		}
	}

	if (defined ($problems->{$problemID . ''})) {
		return ($problems->{$problemID . ''});
	}

	return (undef);
}

# =============================================================================

sub ackHost {
	my ($time, $host, $comment, $author, $sticky, $notify, $persistent) = @_;

	# Open the external commands file
	if (! open (NAGIOS, '>>', $CONFIG->{'command_file'})) {
		# Well shizzle
		return (undef, $!);
	}

	# Success! Write the command
	printf (NAGIOS "[%u] ACKNOWLEDGE_HOST_PROBLEM;%s;%u;%u;%u;%s;%s\n", $time, $host, $sticky, $notify, $persistent, $author, $comment);
	# Close the file handle
	close (NAGIOS);

	# Return with happiness
	return (1, undef);
}

# =============================================================================

sub deackHost {
	my ($time, $host) = @_;

	# Open the external commands file
	if (! open (NAGIOS, '>>', $CONFIG->{'command_file'})) {
		# Well shizzle
		return (undef, $!);
	}

	# Success! Write the command
	printf (NAGIOS "[%u] REMOVE_HOST_ACKNOWLEDGEMENT;%s\n", $time, $host);
	# Close the file handle
	close (NAGIOS);

	# Return with happiness
	return (1, undef);
}

# =============================================================================

sub ackService {
	my ($time, $host, $service, $comment, $author, $sticky, $notify, $persistent) = @_;

	# Open the external commands file
	if (! open (NAGIOS, '>>', $CONFIG->{'command_file'})) {
		# Well shizzle
		return (undef, $!);
	}

	# Success! Write the command
	printf (NAGIOS "[%u] ACKNOWLEDGE_SVC_PROBLEM;%s;%s;%u;%u;%u;%s;%s\n", $time, $host, $service, $sticky, $notify, $persistent, $author, $comment);
	# Close the file handle
	close (NAGIOS);

	# Return with happiness
	return (1, undef);
}

# =============================================================================

sub deackService {
	my ($time, $host, $service) = @_;

	# Open the external commands file
	if (! open (NAGIOS, '>>', $CONFIG->{'command_file'})) {
		# Well shizzle
		return (undef, $!);
	}

	# Success! Write the command
	printf (NAGIOS "[%u] REMOVE_SVC_ACKNOWLEDGEMENT;%s;%s\n", $time, $host, $service);
	# Close the file handle
	close (NAGIOS);

	# Return with happiness
	return (1, undef);
}

# =============================================================================

my ($TIME, $QUERY, $POST, $JSON);

$TIME = time ();

$QUERY = CGI->new ();

if (! defined ($POST = $QUERY->param ('POSTDATA'))) {
	print ("Status: 400 Requests must be POSTs\n\n400 Requests must be POSTs\n");
	exit (0);
}

if (! defined ($JSON = JSON->new ()->utf8 ()->decode ($POST))) {
	print ("Status: 400 Request payload must be JSON blob\n\n400 Request payload must JSON blob\n");
	exit (0);
}

if ((ref ($JSON) ne 'HASH') || ! defined ($JSON->{'messages'}) || (ref ($JSON->{'messages'}) ne 'ARRAY')) {
	print ("Status: 400 JSON blob does not match the expected format\n\n400 JSON blob does not match expected format\n");
	exit (0);
}

my ($message, $return);
$return = {
	'status' => 'okay',
	'messages' => {}
};

MESSAGE: foreach $message (@{$JSON->{'messages'}}) {
	my ($hostservice, $status, $error);

	if ((ref ($message) ne 'HASH') || ! defined ($message->{'type'})) {
		next MESSAGE;
	}

	$hostservice = problemToHostService ($message->{'data'}->{'incident'}->{'incident_key'});

	if (! defined ($hostservice)) {
		next MESSAGE;
	}

	if ($message->{'type'} eq 'incident.acknowledge') {
		if (! defined ($hostservice->{'service'})) {
			($status, $error) = ackHost ($TIME, $hostservice->{'host'}, 'Acknowledged by PagerDuty', 'PagerDuty', 2, 0, 0);

		} else {
			($status, $error) = ackService ($TIME, $hostservice->{'host'}, $hostservice->{'service'}, 'Acknowledged by PagerDuty', 'PagerDuty', 2, 0, 0);
		}

		$return->{'messages'}{$message->{'id'}} = {
			'status' => ($status ? 'okay' : 'fail'),
			'message' => ($error ? $error : undef)
		};

	} elsif ($message->{'type'} eq 'incident.unacknowledge') {
		if (! defined ($hostservice->{'service'})) {
			($status, $error) = deackHost ($TIME, $hostservice->{'host'});

		} else {
			($status, $error) = deackService ($TIME, $hostservice->{'host'}, $hostservice->{'service'});
		}

		$return->{'messages'}->{$message->{'id'}} = {
			'status' => ($status ? 'okay' : 'fail'),
			'message' => ($error ? $error : undef)
		};
		$return->{'status'} = ($status eq 'okay' ? $return->{'status'} : 'fail');
	}
}

printf ("Status: 200 Okay\nContent-type: application/json\n\n%s\n", JSON->new ()->utf8 ()->encode ($return));
