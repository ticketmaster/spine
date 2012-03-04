# -*- mode: perl; cperl-continued-brace-offset: -4; indent-tabs-mode: nil; -*-
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: SystemInfo.pm 271 2009-11-04 20:14:58Z cfb $

#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 3 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# (C) Copyright Ticketmaster, Inc. 2007
#

use strict;

package Spine::Plugin::SystemInfo;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);
use Spine::Util qw(simple_exec);

our ($VERSION, $DESCRIPTION, $MODULE);

$VERSION = sprintf('%d', q$Revision: 271 $ =~ /(\d+)/);
$DESCRIPTION = 'Spine::Plugin system information harvester';

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'DISCOVERY/populate' => [ { name => 'sysinfo',
                                                   code => \&get_sysinfo },
                                                 { name => 'netinfo',
                                                   code => \&get_netinfo },
                                                 { name => 'distro',
                                                   code => \&get_distro },
                                                 { name => 'architecture',
                                                   code => \&get_hw_arch },
                                                 { name => 'is_virtual',
                                                   code => \&is_virtual },
                                                 { name => 'num_procs',
                                                   code => \&get_num_procs } ,
                                                 { name => 'hardware_platform',
                                                   code => \&get_hardware_platform } , 
                                                 { name => 'current_kernel_version',
                                                   code => \&get_current_kernel_version } ]
                     }
          };


use File::Basename;
use File::Spec::Functions;
use IO::File;
use NetAddr::IP;
use Spine::Util qw(resolve_address);

#
# This should really be a much more generic in terms of populating data about
# the devices on the PCI bus and use linux/drivers/pci/pci.ids.  Should really
# just gather various stuff from /proc really.
#
# rtilder    Fri Sep 10 16:17:11 PDT 2004
#
sub get_sysinfo
{
    my $c = shift;
    my ($ip_address, $bcast, $netmask, $netcard);
    my $iface = $c->getval('primary_iface');

    $c->cprint('retrieving system information', 3);

    my ($platform) = simple_exec(c     => $c,
                                 exec  => 'uname',
                                 inert => 1);
                               
    chomp $platform;
    $platform = lc($platform);

    if ($platform =~ m/linux/i)
    {
        # Grab the network_device_map key contents as a hash so we can walk it
        # more quickly
        my $devmap = $c->getvals('network_device_map');
        my %devs;
        if ($devmap) {
            %devs = @{$devmap};
        } else {
            $c->error('the "c_netcard" key will be "unknown" as '.
                        'no "network_device_map" key has been defined',
                      'warn');
        }
        

        # We walk the PCI bus to determine which network card we have
        my @lspci_res = simple_exec(c     => $c,
                                    exec  => 'lspci',
                                    inert => 1);
        return PLUGIN_FATAL unless ($? == 0);
        
        foreach my $line (@lspci_res)
        {
            next unless ($line =~ m/Ethernet/);
            # FIXME  This is kind of dumb.  We don't provide any kind of
            #        interface to driver mapping and we really should
            while (my ($re, $card) = each(%devs)) {
                $netcard = $card if ($line =~ m/$re/);
            }
        }
        $netcard = 'unknown' unless $netcard;

        unless (defined $iface) {
            $c->error('no "primary_iface" key defined', 'crit');
            return PLUGIN_FATAL;
        }

        my @ifconfig_res = simple_exec(c     => $c,
                                       exec  => 'ifconfig',
                                       args  => 'eth' . $iface,
                                       inert => 1);
        return PLUGIN_FATAL unless (@ifconfig_res);

        foreach my $line (@ifconfig_res)
        {
            if ($line =~
                m/
                \s*inet\s+addr:(\d+\.\d+\.\d+\.\d+)
                \s*Bcast:(\d+\.\d+\.\d+\.\d+)
                \s*Mask:(\d+\.\d+\.\d+\.\d+)
                /xi )
            {
                $ip_address = $1;
                $bcast = $2;        
                $netmask = $3;
            }
        }
    }

    $c->{c_platform} = $platform;
    $c->{c_local_ip_address} = $ip_address;
    $c->{c_local_bcast} = $bcast;
    $c->{c_local_netmask} = $netmask;
    $c->{c_netcard} = $netcard;

    $c->get_values("platform/$platform");

    return PLUGIN_SUCCESS;
}

# TODO replace this with something more generic
#      expecting there to be a network directory doesn't
#      make sense.
sub get_netinfo
{
    my $c = shift;
    my $c_root = $c->getval('c_croot');
    my $network_path = $c->getval('network_path') || 'network';
    $c->print(3, 'examining local network');

    # First lets get the IP address in DNS for our hostname.
    $c->{c_ip_address} = resolve_address("$c->{c_hostname}");
    unless ($c->{c_ip_address}) {
        $c->error("Unable to resolve IP address for \"$c->{c_hostname}\"",
                  'crit');
        return PLUGIN_FATAL;
    }

    # Now we need a more usable form of the IP address.
    my ($subnet, $network, $netmask, $bcast, @nets);
    my $nobj = new NetAddr::IP($c->getval('c_ip_address'));

    # FIXME  Incorrect and confusing error message here
    unless (defined($nobj)) {
        $c->error("Error interpreting IP \"$c->{c_hostname}\" (NetAddr::IP)",
                  'crit');
        return PLUGIN_FATAL;
    }
     
    # it will all fall apart if this in not there so lets
    # make life easy for the user and let them know.
    if ( ! -d "${c_root}/${network_path}/" ) {
        $c->error("no \"$c_root/$network_path/\" config directory exists.", 'crit');
        return PLUGIN_FATAL;
    }        

    # Populate an ordered hierarchy of networks that our address is a member
    # of

    foreach my $net (<${c_root}/${network_path}/*>)
    {
        next unless ($net !~ m/^(?:\d{1,3}\.){3}(?:\d{1,3})-\d{1,2}/);
        $net = basename($net);
        $net =~ s@-@/@g;

        my $sobj = new NetAddr::IP($net);

        unless (defined($sobj)) {
            $net =~ s@/@-@g;
            $c->error("Invalid network definition \"$net\"", 'err');
            return PLUGIN_FATAL
        }

        if ($nobj->within($sobj)) {
            push @nets, $sobj;
        }
    }

    @nets = sort { $a->within($b) and return 1;
                   $b->within($a) and return -1;
                   return 0; } @nets;

    $nobj = $nets[-1];
    unless (ref($nobj) eq 'NetAddr::IP') {
        $c->error("unable to find a matching network within \"${c_root}/${network_path}/\"",
                     " for \"$c->{c_ip_address}\"",
                  'crit');
        return PLUGIN_FATAL;
    }

    $c->{c_subnet} = "$nobj"; # stringification of a NetAddr::IP object
    $c->{c_network} = $nobj->network->addr;
    $c->{c_bcast} = $nobj->broadcast->addr;
    $c->{c_netmask} = $nobj->mask();

    $c->{c_network_hierarchy} = [];
    foreach my $net (@nets) {
        $net = "$net";
        $net =~ s@/@-@g;
        push @{$c->{c_network_hierarchy}}, $net;
    }

    $c->print(5, "c_network_hierarchy == \"@{$c->{c_network_hierarchy}}\"");

    unless (defined $c->{c_subnet})
    {
        $c->error("error caculating subnet for \"$c->{c_ip_address}\" ".
                      "using \"$network_path/$nets[-1]\"", 'crit');
        return PLUGIN_FATAL;
    }

    return PLUGIN_SUCCESS;
}

#
# This function detects if the current system is s Vmware or Xen VM
# and the subtype of Xen VM (para virt vs. full hardware emmulation).
#
# Variables:
# c_virtual_type = undef for physical, "vmware" for VMWare, "xen-para" for 
#                  para-virtualized Xen, and "xen-hvm" for full hardware
#                  virtualization under Xen.
#
sub is_virtual
{

    my $c = shift;
    my $xen_indicator = $c->getval('xen_indicator') || qq(/proc/xen/xenbus);

    # First detect xen-para because it is easy
    if ( -f $xen_indicator )
    {
        $c->{c_virtual_type} = 'xen-para';

        return PLUGIN_SUCCESS;
    }
    my @lspci_res = simple_exec(c     => $c,
                                exec  => 'lspci',
                                args  => '-n',
                                inert => 1);
    return PLUGIN_FATAL unless ($? == 0);

    foreach my $line (@lspci_res) {
        # 15ad is the PCI vendor ID for VMWare
        #
        # rtilder   Thu Nov  6 09:45:33 PST 2008
        if ( $line =~ m/\s+15ad:[\da-f]{4}/i ) {
            $c->{c_virtual_type} = 'vmware';
            last;
        }
        # 5853 is the vendor ID for Xen Source (who contribute a lot of
        # code to the Xen project) and 0001 is the device ID for their
        # virtual SCSI adapter so "5853:0001" is a Xen HVM
        if ( $line =~ m/\s+5853:[\da-f]{4}/i ) {
            $c->{c_virtual_type} = 'xen-hvm';
            last;
        }
    }

    return PLUGIN_SUCCESS;
}

sub get_distro
{
    my $c = shift;
    return PLUGIN_SUCCESS;
}


# We don't care much about epoch at the moment.
sub _pkg_vr
{
    my $pkg = shift;

    my $pname = $pkg->tag('name');
    my $pver  = $pkg->tag('version');
    my $prel  = $pkg->tag('release');

    return "$pname-$pver-$prel";
}


#
# Cute trick:
#
# In /proc/cpuinfo, the "clflush" flag is visible even in a 32bit only kernel.
# However, the "clflush size" entry is only available on 64 bit x86
# kernel, no matter if it's AMD or Intel.
#
# rtilder    Fri May  5 13:39:31 PDT 2006
#
sub get_hw_arch
{
    my $c = shift;
    $c->{c_arch} = 'x86';

    my $cpuinfo = new IO::File('< /proc/cpuinfo');

    if (not defined($cpuinfo)) {
        $c->error("Coundn't open /proc/cpuinfo: $!", 'crit');
        return PLUGIN_FATAL;
    }

    while (<$cpuinfo>) {
        if (m/^clflush size.*/) {
            $c->{c_arch} = 'x86_64';
            last;
        }
    }

    $cpuinfo->close();

    $c->print(0, 'running on a ', $c->{c_arch}, ' kernel.');

    return PLUGIN_SUCCESS;
}


sub get_num_procs
{
    my $c = shift;
    my $getconf = qq(/usr/bin/getconf);

    $c->{c_num_procs} = 1;


    my $cpuinfo = new IO::File('< /proc/cpuinfo');
    my $nprocs = 0;

    unless (defined($cpuinfo)) {
        $c->error('Failed to open /proc/cpuinfo', 'err');
        return PLUGIN_FATAL;
    }

    # Try to determine the number of processors
    while(<$cpuinfo>) {
        $nprocs++ if m/^processor\s+:\s+\d+/i;
    }

    $cpuinfo->close();

    $c->{c_num_procs} = $nprocs;

    return PLUGIN_SUCCESS;
}

#
# This is a hack until the Hardware plugin is completed to give us
# some basic idea of what type of system we are running on.
#
sub get_hardware_platform
{

    my $c = shift;

    # If we are are running on a virtual system just return the 
    # the virtual_type
    if (defined $c->{c_virtual_type})
    {
        $c->{c_hardware_platform} = $c->{c_virtual_type};
    }
    else
    {
        my @dmidecode_res = simple_exec(c     => $c,
                                        exec  => 'dmidecode',
                                        inert => 1);
        return PLUGIN_FATAL unless ($? == 0);

        my $sys_section = 0;
        my $hardware_platform = 'UNKNOWN';

        foreach my $line (@dmidecode_res)
        {
            # We need to find the "Product Name:" key under 'DMI type 1'
            # (which is the "System Information" section).
            if ($line =~ m/DMI type 1/i)
            {
                $sys_section = 1;
                next;
            }

            # If we are in the sys_section, look for "Product Name:"
            if ($sys_section and $line =~ m/Product Name:/i)
            {
                (undef, $hardware_platform) = split(': ', $line, 2);
                $hardware_platform =~ s/^\s+|\s+$//g;
                $hardware_platform = 'UNKNOWN' if $hardware_platform eq '';
                last;
            } 

            # If we enter another DMI section we are done.
            last if ($sys_section and $line =~ m/DMI type/i);
        }

        $c->{c_hardware_platform} = $hardware_platform;
    }
    return PLUGIN_SUCCESS;
}

sub get_current_kernel_version
{
    my $c = shift;
    my $release_file = qq(/proc/sys/kernel/osrelease);
    my $fh = new IO::File("< $release_file");

    unless (defined($fh))
    {
        $c->error("Couldn't open $release_file: $!", 'err');
        return PLUGIN_FATAL;
    }

    my $running_kernel = $fh->getline();
    chomp $running_kernel;
    $fh->close();

    $c->print(3, "detected running kernel \[$running_kernel\]");

    $c->set('c_current_kernel_version', $running_kernel);

    return PLUGIN_SUCCESS;
}


1;
