#!/usr/bin/env perl

use warnings;
use strict;

use JSON;
use LWP::UserAgent;
use Getopt::Long qw/:config no_ignore_case bundling auto_abbrev/;

# =============================================================================

sub loadEnvironment {
	my (%env) = @_;
	my ($return, $key, @entry);

	$return = {};

	foreach $key (keys (%env)) {
		@entry = ($key);

		next unless ($entry [0] =~ /^NAGIOS_(\S+)$/i) || ($entry[0] =~ /^ICINGA_(\S+)$/i);

		$entry [1] = lc ($1);

		if ($entry [1] =~ /^(ADMIN|MAX|NOTIFICATION)(\S+)$/i) {
			$entry [1] = $1;
			$entry [2] = $2;

			if (! defined ($return->{$entry [1]})) {
				$return->{$entry [1]} = {};
			}
			$return->{$entry [1]}->{$entry [2]} = $env {$entry [0]};

		} elsif ($entry [1] =~ /^(ARG)(\d+)$/i) {
			$entry [1] = $1;
			$entry [2] = $2;

			if (! defined ($return->{$entry [1]})) {
				$return->{$entry [1]} = [];
			}
			$return->{$entry [1]}->[$entry [2] - 1] = $env {$entry [0]};

		} elsif ($entry [1] =~ /^(CONTACT)(\S+)$/i) {
			$entry [1] = $1;
			$entry [2] = $2;

			if (! defined ($return->{$entry [1]})) {
				$return->{$entry [1]} = {};
			}

			if ($entry [2] =~ /^(ADDRESS)(\d+)$/i) {
				$entry [2] = $1;
				$entry [3] = $2;

				if (! defined ($return->{$entry [1]}->{$entry [2]})) {
					$return->{$entry [1]}->{$entry [2]} = [];
				}
				$return->{$entry [1]}->{$entry [2]}->[$entry [3]] = $env {$entry [0]};

			} elsif ($entry [2] =~ /^(GROUP)(\S+)$/i) {
				$entry [2] = $1;
				$entry [3] = $2;

				if (! defined ($return->{$entry [1]}->{$entry [2]})) {
					$return->{$entry [1]}->{$entry [2]} = {};
				}
				$return->{$entry [1]}->{$entry [2]}->{$entry [3]} = $env {$entry [0]};

			} else {
				$return->{$entry [1]}->{$entry [2]} = $env {$entry [0]};
			}

		} elsif ($entry [1] =~ /^(HOST|SERVICE)(\S+)$/i) {
			$entry [1] = $1;
			$entry [2] = $2;

			if (! defined ($return->{$entry [1]})) {
				$return->{$entry [1]} = {};
			}

			if ($entry [2] =~ /^(ACK|GROUP|CHECK|NOTIFICATION)(\S+)$/i) {
				$entry [2] = $1;
				$entry [3] = $2;

				if (! defined ($return->{$entry [1]}->{$entry [2]})) {
					$return->{$entry [1]}->{$entry [2]} = {};
				}
				$return->{$entry [1]}->{$entry [2]}->{$entry [3]} = $env {$entry [0]};

			} else {
				$return->{$entry [1]}->{$entry [2]} = $env {$entry [0]};
			}

		} elsif ($entry [1] =~ /^(LAST)(\S+)$/i) {
			$entry [1] = $1;
			$entry [2] = $2;

			if (! defined ($return->{$entry [1]})) {
				$return->{$entry [1]} = {};
			}

			if ($entry [2] =~ /^(HOST|SERVICE)(\S+)$/i) {
				$entry [2] = $1;
				$entry [3] = $2;

				if (! defined ($return->{$entry [1]}->{$entry [2]})) {
					$return->{$entry [1]}->{$entry [2]} = {};
				}
				$return->{$entry [1]}->{$entry [2]}->{$entry [3]} = $env {$entry [0]};

			} else {
				$return->{$entry [1]}->{$entry [2]} = $env {$entry [0]};
			}

		} elsif ($entry [1] =~ /^(TOTAL)(\S+)$/i) {
			$entry [1] = $1;
			$entry [2] = $2;

			if (! defined ($return->{$entry [1]})) {
				$return->{$entry [1]} = {};
			}

			if ($entry [2] =~ /^(HOSTS|HOST|SERVICES|SERVICE)(\S+)$/i) {
				$entry [2] = $1;
				$entry [3] = $2;

				if (! defined ($return->{$entry [1]}->{$entry [2]})) {
					$return->{$entry [1]}->{$entry [2]} = {};
				}
				$return->{$entry [1]}->{$entry [2]}->{$entry [3]} = $env {$entry [0]};

			} else {
				$return->{$entry [1]}->{$entry [2]} = $env {$entry [0]};
			}

		} else {
			$return->{lc ($entry [1])} = $env {$entry [0]};
		}
	}

	$return->{'type'} = 'host';
	if ($return->{'last'} && $return->{'last'}->{'service'} && $return->{'last'}->{'service'}->{'check'}) {
		$return->{'type'} = 'service';
	}

	return ($return);
}

# =============================================================================

my (%OPTIONS);

%OPTIONS = (
	'api_url' => 'https://events.pagerduty.com/generic/2010-04-15/create_event.json',
);

GetOptions (
	'a|apiurl=s' => \$OPTIONS {'api_url'},
) || (
	exit (1)
);

# =============================================================================

my ($event, $nagios);

$nagios = loadEnvironment (%ENV);
$event = {
	'service_key' => $nagios->{'contact'}->{'pager'},
	'incident_key' => undef,
	'event_type' => undef,
	'description' => undef,
	'details' => $nagios,
};

if (! defined ($event->{'client_url'})) {
	delete ($event->{'client_url'});
}

if ($nagios->{'type'} eq 'host') {
	if ($nagios->{'notification'}->{'type'} eq 'RECOVERY') {
		$event->{'incident_key'} = $nagios->{'last'}->{'host'}->{'problemid'};

	} else {
		$event->{'incident_key'} = $nagios->{'host'}->{'problemid'};
	}

} elsif ($nagios->{'type'} eq 'service') {
	if ($nagios->{'notification'}->{'type'} eq 'RECOVERY') {
		$event->{'incident_key'} = $nagios->{'last'}->{'service'}->{'problemid'};

	} else {
		$event->{'incident_key'} = $nagios->{'service'}->{'problemid'};
	}
}

if (($nagios->{'notification'}->{'type'} eq 'PROBLEM') || ($nagios->{'notification'}->{'type'} eq 'RECOVERY')) {
	$event->{'event_type'} = ($nagios->{'notification'}->{'type'} eq 'PROBLEM' ? 'trigger' : 'resolve');

	if ($nagios->{'type'} eq 'host') {
		$event->{'description'} =
			$nagios->{'host'}->{'state'} .
			': ' .
			$nagios->{'host'}->{'name'} .
			' reports ' .
			$nagios->{'host'}->{'output'};

	} elsif ($nagios->{'type'} eq 'service') {
		$event->{'description'} =
			$nagios->{'service'}->{'state'} .
			': ' .
			$nagios->{'service'}->{'notes'} .
            ' ' .
			($nagios->{'service'}->{'displayname'} ? $nagios->{'service'}->{'displayname'} : $nagios->{'service'}->{'desc'}) .
			' on ' .
			$nagios->{'host'}->{'name'} .
			' reports ' .
			$nagios->{'service'}->{'output'};
	}

} elsif ($nagios->{'notification'}->{'type'} eq 'ACKNOWLEDGEMENT') {
	$event->{'event_type'} = 'acknowledge';

	if ($nagios->{'type'} eq 'host') {
		$event->{'description'} =
			$nagios->{'host'}->{'state'} .
			' for ' .
			$nagios->{'host'}->{'name'} .
			' acknowledged by ' .
			$nagios->{'notification'}->{'author'} .
			' saying ' .
			$nagios->{'notification'}->{'comment'};

	} elsif ($nagios->{'type'} eq 'service') {
		$event->{'description'} =
			$nagios->{'service'}->{'state'} .
			' for ' .
			($nagios->{'service'}->{'displayname'} ? $nagios->{'service'}->{'displayname'} : $nagios->{'service'}->{'desc'}) .
			' on ' .
			$nagios->{'host'}->{'name'} .
			' acknowledged by ' .
			$nagios->{'notification'}->{'author'} .
			' saying ' .
			$nagios->{'notification'}->{'comment'};
	}

} else {
	exit (0);
}

# =============================================================================

my ($time, $host, $service) = @_;
my ($useragent, $response);

$useragent = LWP::UserAgent->new ();
$response = $useragent->post (
	$OPTIONS {'api_url'},
	'Content_Type' => 'application/json',
	'Content' => JSON->new ()->utf8 ()->encode ($event)
);

if (! $response->is_success ()) {
	exit (1);
}

exit (0);
