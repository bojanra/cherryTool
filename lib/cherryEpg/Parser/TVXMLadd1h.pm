package cherryEpg::Parser::TVXMLadd1h;

use 5.024;
use utf8;
use Moo;

extends 'cherryEpg::Parser::TVXMLdirty';

our $VERSION = '0.23';

=head1

Shift events 1 hour in future.

=cut

after 'parse' => sub {
  my $output = shift;
  my $report = $output->{report}->{eventList};

  foreach my $event ( @{$report} ) {
    $event->{start} += 1 * 60 * 60;
    $event->{stop}  += 1 * 60 * 60 if $event->{stop} && $event->{stop} =~ /^\d+$/;
  }
}; ## end 'parse' => sub

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
