
# vim:shiftwidth=2:tabstop=8:expandtab:textwidth=78:softtabstop=4:ai:

# $Id: Skeleton.pm 22 2007-12-12 00:35:55Z phil@ipom.com $

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

package Spine::Plugin::Parselet::Dynamic;
use base qw(Spine::Plugin);
use Spine::Constants qw(:plugin);


our ($VERSION, $DESCRIPTION, $MODULE);
my $CPATH;

my $init = 0;

$VERSION = sprintf("%d.%02d", q$Revision: 22 $ =~ /(\d+)\.(\d+)/);
$DESCRIPTION = "Parselet::Dynamic, detects if the object can be expanded";

$MODULE = { author => 'osscode@ticketmaster.com',
            description => $DESCRIPTION,
            version => $VERSION,
            hooks => { 'PARSE/key' => [ { name => "Dynamic", 
                                          code => \&check_dynamic,
                                          requires => ['complex'],
                                          provides => ['dynamic'] } ],
                     },
          };

sub create_phase {

    my $registry = shift;

    $registry->create_hook_point(qw(PARSE/key/dynamic));

    # We only want to do this once...
    $init = 1;
}


# This means we only have to check if the key is dynamic once
# and cut's down the number of plugins we have to cascade through
sub check_dynamic {
    my ($c, $data) = @_;

    # only hash refs  / complex
    unless (ref($data->{obj}) eq 'HASH') {
        return PLUGIN_SUCCESS;
    }

    # If the object contains dynamic_type then we
    # will kick it through the PARSE/key/dynamic phase
    unless (exists $data->{obj}->{dynamic_type}) {
        return PLUGIN_SUCCESS;
    }

    my $registry = new Spine::Registry();
    # If this is the first one we have to create the
    # hook point
    create_phase($registry) unless ($init);
    # HOOKME: Dynamic complex keys
    my $point = $registry->get_hook_point("PARSE/key/dynamic");
    # HOOKME, go through ALL dynamic plugins
    my $rc = $point->run_hooks_until(PLUGIN_FATAL, $c, $data);
    if ($rc & PLUGIN_FATAL) {
        $c->error("There was a problem getting key data", 'crit');
        return PLUGIN_ERROR;
    }
    return PLUGIN_SUCCESS;
}

1;