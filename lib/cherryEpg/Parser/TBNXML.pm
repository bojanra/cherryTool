package cherryEpg::Parser::TBNXML;

use 5.024;
use utf8;
use Moo;

extends 'cherryEpg::Parser::TVXMLdirty';

our $VERSION = '0.26';

sub _handler_class {'TBNXMLHandler'}

package TBNXMLHandler;
use Moo;
use Time::Piece;
use Try::Tiny;
use Carp qw( croak );

extends 'TVXMLdirtyHandler';

# <programme channel="ocean-tv.su" start="20260914120000 +0300">
sub decode_timestamp {
  my ( $self, $t ) = @_;

  return if !$t;

  $t =~ s/://g;                           # remove colon from timezone
  $t =~ s/-//g;                           # remove dash
  $t =~ s/T//;                            # remove T between date and time
  $t .= " +0000" if $t =~ m/^\d{14}$/;    # add timezone UTC if missing
  $t =~ s/(\d)\s?(\d{4})$/$1+$2/;         # insert missing plus in front of timezone

  # <programme channel="ocean-tv.su" start="20260914120000 +0300">
  #                                         20260914120000 +0300
  my ( $year, $month, $day, $hour, $minute, $second, $timezone ) = ( $t =~ m/^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2}) (.+)$/ )
      or return;

  # detect new broadcast day
  if ( !exists $self->{lastDay} || $day != $self->{lastDay} ) {
    $self->{lastDay}  = $day;
    $self->{newDay}   = 1;
    $self->{lastHour} = 0;
    $self->{pm}       = 0;
  } ## end if ( !exists $self->{lastDay...})

  # the "new day" window only applies to the first hours after midnight
  $self->{newDay} = 0 if $hour < 12;

  # a "12" right at the start of a new day means midnight, not noon
  $hour -= 12 if $self->{newDay} && $hour == 12;

  # detect change to afternoon
  $self->{pm} = 1 if $hour < $self->{lastHour};
  $hour += 12     if $self->{pm};

  $self->{lastHour} = $hour;

  # rebuild the timestamp with the corrected hour
  $t = sprintf( "%04d%02d%02d%02d%02d%02d %s", $year, $month, $day, $hour, $minute, $second, $timezone );

  try {
    Time::Piece->strptime( $t, "%Y%m%d%H%M%S %z" )->epoch;
  };
} ## end sub decode_timestamp

1;

=head1 AUTHOR

This software is copyright (c) 2026 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut
