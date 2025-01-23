package cherryEpg::Parser::LazyJSON;

use 5.024;
use utf8;
use JSON::XS;
use Moo;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;

extends 'cherryEpg::Parser';

our $VERSION = '0.14';

sub BUILD {
  my ( $self, $arg ) = @_;

  $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => array of events found

=cut

sub parse {
  my ( $self, $option ) = @_;
  my $report = $self->{report};

  my $content = try {
    local $/;
    open( my $fh, '<:encoding(UTF-8)', $self->{source} ) || return;
    <$fh>;
  };

  if ( !$content ) {
    $self->error("File empty");
    return $report;
  }

  my $data = JSON::XS->new->decode($content);

  if ( !$data ) {
    $self->error("Content not in JSON format");
    return $report;
  }

  foreach my $item ( @{$data} ) {
    my $event;

    if ( $item->{start_time} ) {
      $event->{start} = try {

        # convert 2025-01-21T20:29:28.000-05:00
        #      to 2025-01-21T20:29:28-0500
        $item->{start_time} =~ m/(\d+)-(\d+)-(\d+)T(\d+):(\d+):(\d+)\.?\d*([+-])(\d{2}):?(\d{2})$/;
        my $t = "$1-$2-$3T$4:$5:$6$7$8$9";
        gmtime->strptime( $t, "%Y-%m-%dT%H:%M:%S %z" )->epoch;
      } catch {
        $self->error("start_time not valid format [$item->{start_time}]");
      };
    } ## end if ( $item->{start_time...})
    $event->{duration} = $item->{duration} if $item->{duration};
    $event->{title}    = $item->{program}  if $item->{program};
    $event->{subtitle} = $item->{ep_name}  if $item->{ep_name};
    $event->{synopsis} = $item->{host}     if $item->{host};
    $event->{id}       = $item->{id}       if $item->{id};

    push( @{ $report->{eventList} }, $event );
  } ## end foreach my $item ( @{$data})

  return $report;
} ## end sub parse

=head1 AUTHOR

This software is copyright (c) 2025 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
