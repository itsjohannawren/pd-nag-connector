#!/usr/bin/env perl

use warnings;
use strict;

use JSON;
use Fcntl qw/:flock/;
use LWP::UserAgent;
use Getopt::Long qw/:config no_ignore_case bundling auto_abbrev/;

# =============================================================================

my (%DEFAULTS, %OPTIONS, $LOCK);

# Set defaults and options at the same time rather
%DEFAULTS = %OPTIONS = (
	'help' => undef,
	'api_url' => 'https://events.pagerduty.com/generic/2010-04-15/create_event.json',
	'queue_dir' => '/tmp/pd-nag-connector',
	'enqueue_only' => undef,
	'run_queue' => undef,
	'purge_queue' => undef,
	'clean_queue' => undef
);
# Get options
GetOptions (
	'h|help' => \$OPTIONS {'help'},
	'a|apiurl=s' => \$OPTIONS {'api_url'},
	'q|queuedir=s' => \$OPTIONS {'queue_dir'},
	'e|enqueue|enqueueonly' => \$OPTIONS {'enqueue_only'},
	'r|run|runqueue' => \$OPTIONS {'run_queue'},
	'p|purge|purgequeue:0' => \$OPTIONS {'purge_queue'},
	'c|clean|cleanqueue' => \$OPTIONS {'clean_queue'}
) || (
	usage (1)
);

# Change the defined value of help to 0
if (defined ($OPTIONS {'help'})) {
	$OPTIONS {'help'} = 0;
	usage ($OPTIONS {'help'});
}

# Check for a valid API URL
if ($OPTIONS {'api_url'} !~ /^https?:\/\/(?:([^:]+):([^@]+)@)?([0-9a-z_.-]+)(?:\/.*)?$/i) {
	printf (STDERR "Error: Invalid API URL: %s\n", $OPTIONS {'api_url'});
	exit (1);
}

# Queue directory must be an absolute path
if ($OPTIONS {'queue_dir'} !~ /^\//) {
	printf (STDERR "Error: Invalid queue directory (must be absolute): %s\n", $OPTIONS {'queue_dir'});
	exit (1);
}

# Purge value must be 0 of a positive integer
if (defined ($OPTIONS {'purge_queue'}) && ($OPTIONS {'purge_queue'} < 0)) {
	printf (STDERR "Error: Invalid purge seconds (must be >= 0): %i\n", $OPTIONS {'purge_queue'});
	exit (1);
}

# Check for queue directory
if (! -d $OPTIONS {'queue_dir'}) {
	# Not a directory, but does it exist?
	if (-e $OPTIONS {'queue_dir'}) {
		printf (STDERR "Error: Queue directory exists, but is not a directory: %s\n", $OPTIONS {'queue_dir'});
		exit (1);
	}
	# Try to make the directory
	if (! mkdir ($OPTIONS {'queue_dir'})) {
		printf (STDERR "Error: Failed to create queue directory (%s): %s\n", $!, $OPTIONS {'queue_dir'});
		exit (1);
	}
	# Don't trust a mkdir() success
	if (! -d $OPTIONS {'queue_dir'}) {
		printf (STDERR "Error: Failed to create queue directory (%s): %s\n", $!, $OPTIONS {'queue_dir'});
		exit (1);
	}
}
# Check queue directory permissions
if (! -r $OPTIONS {'queue_dir'} || ! -w $OPTIONS {'queue_dir'} || ! -x $OPTIONS {'queue_dir'}) {
	printf (STDERR "Error: Missing all required permissions on queue directory (rwx): %s\n", $!, $OPTIONS {'queue_dir'});
	exit (1);
}

# =============================================================================

my ($status, $message);

# Let's do stuff!
if ($OPTIONS {'purge_queue'} || $OPTIONS {'run_queue'}) {
	# Purge the queue of old events
	if ($OPTIONS {'purge_queue'}) {
		($status, $message) = purgeEvents ($OPTIONS {'purge_queue'});
		if (! defined ($status)) {
			printf (STDERR "Error: %s\n", $message);
			exit (1);
		}
	}
	# Run through the queue and deliver events to PagerDuty
	if ($OPTIONS {'run_queue'}) {
		($status, $message) = deliverEvents ();
		if (! defined ($status)) {
			printf (STDERR "Error: %s\n", $message);
			exit (1);
		}
	}

} else {
	# We're not purging or running, so enqueue
	($status, $message) = enqueueEvent ();
	if (! defined ($status)) {
		printf (STDERR "Error: %s\n", $message);
		exit (1);
	}
	if (! $OPTIONS {'enqueue_only'}) {
		($status, $message) = deliverEvents ();
	}
}

# =============================================================================

sub usage {
	my $return = shift || 0;

	printf (<<'EOF', $0, $DEFAULTS {'api_url'}, $DEFAULTS {'queue_dir'});
Usage: %s [OPTIONS]

  -h  --help               Shows this help.
  -a  --apiurl    URL      Overrides the PagerDuty API endpoint URL.
                           Default: %s
  -q  --queuedir  PATH     Overrides the local queue directory.
                           Default: %s
  -e  --enqueue            Only enqueue an event, do not attempt immediate
                           delivery to PagerDuty.
  -r  --run                Run through queue attempting to deliver events to
                           PagerDuty. Does not add a new event to the queue.
  -p  --purge     SECONDS  Purge events from queue that are older than the
                           specified number of seconds.
  -c  --clean              Remove all unrecognized files from the queue
                           directory while purging.

EOF
	exit ($return);
}

# =============================================================================

sub lockQueue {
	# Try to open the lockfile, creating it if neccessary
	if (! open ($LOCK, '>>', sprintf ('%s/.lock', $OPTIONS {'queue_dir'}))) {
		# Hmm... That didn't work
		return (undef);
	}
	# Attempt to get an exclusive lock on the file
	if (! flock ($LOCK, LOCK_EX)) {
		# Well, shizzle
		return (undef);
	}

	# Who's in charge?! WE'RE IN CHARGE!
	return (1);
}

sub unlockQueue {
	# Only do work if the lock is set
	if (defined ($LOCK)) {
		# Unlock the file
		flock ($LOCK, LOCK_UN);
		# Close the lock file
		close ($LOCK);
		# Reset the lock variable to undef
		$LOCK = undef;
	}

	# Always return true
	return (1);
}

# =============================================================================

sub loadEnvironment {
	my (%env) = @_;
	my ($return, $key, @entry);

	$return = {};

	foreach $key (keys (%env)) {
		@entry = ($key);

		next unless ($entry [0] =~ /^(?:NAGIOS|ICINGA)_(\S+)$/i);

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

sub enqueueEvent {
	my ($event, $nagios, $file);

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

	if (! defined ($nagios->{'notification'}->{'type'})) {
		return (0);
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
				$nagios->{'host'}->{'output'} .
				' (' .
				$nagios->{'host'}->{'check'}->{'command'} .
				')';

		} elsif ($nagios->{'type'} eq 'service') {
			$event->{'description'} =
				$nagios->{'service'}->{'state'} .
				': ' .
				($nagios->{'service'}->{'displayname'} ? $nagios->{'service'}->{'displayname'} : $nagios->{'service'}->{'desc'}) .
				' on ' .
				$nagios->{'host'}->{'name'} .
				' reports ' .
				$nagios->{'service'}->{'output'} .
				' (' .
				$nagios->{'service'}->{'check'}->{'command'} .
				')';
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
		return (0);
	}

	# Set the file name so we're not building every time
	$file = sprintf ('%s/%010i.%i.json', $OPTIONS {'queue_dir'}, time (), $$);
	# Open the queue file with a temporary extension
	if (! open (FILE, '>', $file . '.tmp')) {
		# Ahhh... that's unfortunate
		return (undef, sprintf ('Failed to open %s: %s', $file, $!));
	}
	# Throw our blob in it
	print (FILE JSON->new ()->utf8 ()->encode ($event));
	# Close the temporary file
	close (FILE);

	# Rename the temporary file to its permanent name
	if (! rename ($file . '.tmp', $file)) {
		# Are you serious?
		return (undef, sprintf ('Failed to rename %s to %s: %s', $file . '.tmp', $file, $!));
	}

	# Success has been had
	return (1);
}

# =============================================================================

sub deliverEvents {
	my $max_age = shift || 0;
	my ($file, $return, $data, $event);

	# Lock the queue because crazy things are gonna happen
	if (! lockQueue ()) {
		# Whoa, pump the brakes
		return (undef, 'Failed to get lock');
	}

	# Using this to store how many events were delivered
	$return = 0;

	# Open the queue directory
	if (! opendir (DIR, $OPTIONS {'queue_dir'})) {
		# Uh, what?
		return (undef, sprintf ('Failed to open queue directory: %s', $!));
	}
	# Loop through all the file directory entries, filtering . and .. just to be safe
	foreach $file (grep {! /^\.{1,2}$/ && -f sprintf ('%s/%s', $OPTIONS {'queue_dir'}, $_)} readdir (DIR)) {
		if ($file =~ /^(\d+)\.\d+\.json$/) {
			# Clear everything up
			$data = '';
			$event = undef;

			# A queued event
			if (! open (FILE, '<', sprintf ('%s/%s', $OPTIONS {'queue_dir'}, $file))) {
				# Duh-what?
				printf (STDERR 'Warning: Failed to open %s: %s', $file, $!);
				next;
			}

			# Read in the blob one line at a time
			while (<FILE>) {
				$data .= $_;
			}

			# Make sure it's a valid blob
			$event = JSON->new ()->utf8 ()->decode ($data);
			# Is it?
			if (! defined ($event)) {
				# Sucky
				printf (STDERR 'Warning: %s contains an invalid JSON blob', $file);
				# Nuke it until glass, wipe with Windex (R)
				if (! unlink (sprintf ('%s/%s', $OPTIONS {'queue_dir'}, $file))) {
					printf (STDERR 'Warning: Failed to remove %s: %s', $file, $!);
				}
				next;
			}

			# Attempt to deliver the event to PagerDuty
			if (! deliverEvent ($event)) {
				# Gah, just can't win today
				printf (STDERR 'Warning: Failed to deliver %s', $file);
				next;
			}

			# Success!
			$return++;
			# Remove the queue file so we don't send it again
			if (! unlink (sprintf ('%s/%s', $OPTIONS {'queue_dir'}, $file))) {
				printf (STDERR 'Warning: Failed to remove %s: %s', $file, $!);
			}
		}
	}

	# All done! Close the directory
	closedir (DIR);
	# Let other people play!
	unlockQueue ();

	# Done
	return ($return);
}

# =============================================================================

sub deliverEvent {
	my ($event) = @_;
	my ($useragent, $response);

	# Construct a fresh user agent
	$useragent = LWP::UserAgent->new ();
	# Send the JSON blob to the API endpoint
	$response = $useragent->post (
		$OPTIONS {'api_url'},
		'Content_Type' => 'application/json',
		'Content' => JSON->new ()->utf8 ()->encode ($event)
	);

	# Success?
	if (! $response->is_success ()) {
		# Boooooo
		return (0);
	}

	# Yay!
	return (1);
}

# =============================================================================

sub purgeEvents {
	my $max_age = shift || 0;
	my ($file, $return);

	# Lock the queue because we're about to delete stuff
	if (! lockQueue ()) {
		# Hold the phone, this ain't good
		return (undef, 'Failed to get lock');
	}

	# Using this to store how many files were removed
	$return = 0;

	# Open the queue directory
	if (! opendir (DIR, $OPTIONS {'queue_dir'})) {
		# Uh, what?
		return (undef, sprintf ('Failed to open queue directory: %s', $!));
	}
	# Loop through all the file directory entries, filtering . and .. just to be safe
	foreach $file (grep {! /^\.{1,2}$/ && -f sprintf ('%s/%s', $OPTIONS {'queue_dir'}, $_)} readdir (DIR)) {
		if ($file =~ /^(\d+)\.\d+\.json$/) {
			# A queued event
			if ($1 + $max_age <= time ()) {
				# Too old!
				if (unlink (sprintf ('%s/%s', $OPTIONS {'queue_dir'}, $file))) {
					$return++;

				} else {
					printf (STDERR 'Warning: Failed to remove %s: %s', $file, $!);
				}
			}

		} elsif ($file =~ /^(\d+)\.\d+\.json\.tmp$/) {
			# A temporary event that should exist for more than a few seconds
			if ($1 + 30 <= time ()) {
				# Yeesh, something went wrong there
				if (unlink (sprintf ('%s/%s', $OPTIONS {'queue_dir'}, $file))) {
					$return++;

				} else {
					printf (STDERR 'Warning: Failed to remove %s: %s', $file, $!);
				}
			}

		} elsif ($file =~ /^\.lock$/) {
			# We're not going to touch this, but we need something here so .lock doesn't get caught below

		} else {
			# I don't recognize this...
			if ($OPTIONS {'clean_queue'}) {
				# Scrub it until it shines!
				if (unlink (sprintf ('%s/%s', $OPTIONS {'queue_dir'}, $file))) {
					$return++;

				} else {
					printf (STDERR 'Warning: Failed to remove %s: %s', $file, $!);
				}
			}
		}
	}

	# All done! Close the directory
	closedir (DIR);
	# Let other people play!
	unlockQueue ();

	# Fin
	return ($return);
}
