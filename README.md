pd-nag-connector
================

A bi-directional integration package for Nagios and PagerDuty making use of
PagerDuty's generic integration API and webhooks to send notifications from
Nagios to PagerDuty and to keep alert acknowledgment status in sync.

Author
------

* Jeff Walter (<jeff@404ster.com>, http://jeffw.org/)

Copyright and License
---------------------

Copyright (C) 2014 Jeff Walter

This software is licensed under the MIT License. Please read the included file
`LICENSE` for more details.

Requirements
------------

* Linux
* Nagios 3.x (Nagwin is **untested**)
    
Installation
------------

### Prerequisites

#### Nagios

Nagios needs to be configured to allow external commands. In your `nagios.cfg`
be sure the following settings have the required value:

* `check_external_commands = 1` to enabled external commands.
* `command_check_interval = -1` to check for external commands as often as
  possible.

Remember to restart Nagios if you made any changes.

#### Debian/Ubuntu

    apt-get install libwww-perl libjson-perl

#### Redhat/CentOS

    yum install perl-libwww-perl perl-JSON

#### Generic

    cpan libwww-perl JSON

### pd-nag-connector

Clone this repository to somewhere on the Nagios server. I suggest
`/opt/pd-nag-connector`.

    cd /opt
    git clone https://github.com/jeffwalter/pd-nag-connector.git

Two files need to be installed:

1. The CGI script `pagerduty.cgi` needs to be linked into the Nagios `cgi-bin`.
   On my system this is found in `/usr/lib/cgi-bin/nagios3`, yours may be
   different. You can discover what it is by looking in your httpd config.

        ln -s /opt/pd-nag-connector/pagerduty.cgi /usr/lib/cgi-bin/nagios3/pagerduty.cgi

2. The gateway script `pagerduty.pl` needs to be installed as a contact method in
   Nagios. We need to do one of the following:
   * Put it in whatever path `$USER1$` in Nagios is by doing
     `ln -s /opt/pd-nag-connector/pagerduty.pl /usr/lib/nagios/plugins/pagerduty.pl`,
     taking care to replace the destination path with the value of `$USER1`.
   * Create another `$USER#$` variable to point to `/opt/pd-nag-connector`.
   * Hard-code the path into the command.

Configuration
-------------

### CGI

At the top of the CGI script there are two values in the `$CONFIG` variable
that you need to set.

* `command_file` should be set to the same value as `command_file` in your
  `nagios.cfg`.
* `status_file` should be set to the same value as `status_file` in your
  `nagios.cfg`.

### Gateway

No configuration is needed since everything comes from the contact definition
in Nagios.

Use
---

### PagerDuty

If you don’t already have a PagerDuty "Generic API" service, you should create
one:

1. In your account, under the **Services** tab, click **Add New Service**.
2. Enter a name for the service and select an escalation policy. Then, select
   **Use our API directly** for the **Integration Type**.
3. Click the **Add Service** button.
4. Once the service is created you’ll be taken to the service page. On this
   page you’ll see the **Service API key**; save this because you will need it
   when you configure your Nagios server to send events to PagerDuty.
5. Setup the webhook for PagerDuty to talk back to Nagios by clicking the
   **Add Webhook** button, giving the hook a name, and specifying the URL to
   access `pagerduty.cgi` (will look like
   `http://example.com/nagios3/cgi-bin/pagerduty.cgi`). If you need HTTP simple
   auth be sure to specify it in the URL.

### In Nagios

How you installed the gateway script decided how you will now reference it in
the contact definitions you're about to create. If you placed a symlink in
`$USER1$` replace **\<PATH\>** with **$USER1$**. If you created a new `$USER#$`
macro that points to `/opt/pd-nag-connector` replace **\<PATH\>** with **$USER#$**.
And if you want to hard-code the path replace **\<PATH\>** with
**/opt/pd-nag-connector**.

    define command {
        command_name    notify-service-by-pagerduty
        command_line    <PATH>/pagerduty.pl
    }
    define command {
        command_name    notify-host-by-pagerduty
        command_line    <PATH>/pagerduty.pl
    }

There is no need to pass anything to the gateway script as everything that's
needed is passed via environment variables. The script internally determines if
the notification is for a host or service.

Create a timeperiod definition that covers 24/7/365:

    define timeperiod {
        timeperiod_name 24-7-365
        alias 24-7-365
        sunday 00:00-24:00
        monday 00:00-24:00
        tuesday 00:00-24:00
        wednesday 00:00-24:00
        thursday 00:00-24:00
        friday 00:00-24:00
        saturday 00:00-24:00
    }

Now create a contact that uses the new command and is used all the time
replacing **\<APIKEY\>** with the **Service API key** from PagerDuty.

    define contact {
        contact_name pagerduty-nagios
        alias pagerduty-nagios
        service_notification_period 24-7-365
        host_notification_period 24-7-365
        service_notification_options w,u,c,r
        host_notification_options d,u,r
        service_notification_commands notify-service-by-pagerduty
        host_notification_commands notify-host-by-pagerduty
        pager <APIKEY>
    }

You can create multiple contact records for different PagerDuty services by
changing the `contact_name` and `alias` values; I recommend keeping the
`pagerduty-` prefix so it is immediately known what the contact does. Don't
forget to specify the correct **\<APIKEY\>** for the new PagerDuty service.

Lastly, assign the contact to hosts and services.

Monitoring
----------

*Implementing in a future version*
