package cherryEpg::Parser::KrimiXML;

use 5.024;
use utf8;
use Moo;
use XML::Parser::PerlSAX;
use Try::Tiny;

extends 'cherryEpg::Parser';

our $VERSION = '0.46';

sub BUILD {
  my ( $self, $arg ) = @_;

  $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => array of events found

The $parserOption is used for setting timeshift and country_code for parental_rating_descriptor.
The options are separated by "," or "|". The first option is used for timeshift and the second for country_code.
Slovakia is detected from the XML source.
=cut

sub parse {
  my ( $self, $parserOption ) = @_;
  my $report = $self->{report};

  my ( $offset, $country_code ) = split( /[\|,]/, $parserOption // '' );

  $offset //= 0;

  my $handler = KrimiXMLHandler->new($country_code);
  my $parser  = XML::Parser::PerlSAX->new(
    Handler => $handler,
    output  => $report
  );

  try {
    $parser->parse( Source => { SystemId => $self->{source} } );
  } catch {
    my ($error) = @_;
    if ( $error =~ m|(.+) at /| ) {
      $self->error($1);
    } else {
      $self->error($error);
    }
  };

  my $eventList = $report->{eventList};

  foreach my $event ( @{$eventList} ) {
    $event->{start} += $offset * 60 * 60;
    $event->{stop}  += $offset * 60 * 60 if $event->{stop} && $event->{stop} =~ /^\d+$/;
  }

  return $report;
} ## end sub parse

package KrimiXMLHandler;
use Moo;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;

has eventList    => ( is => 'rw', default => sub { [] } );
has errorList    => ( is => 'rw', default => sub { [] } );
has currentEvent => ( is => 'rw' );
has currentData  => ( is => 'rw' );
has rawText      => ( is => 'rw' );
has linecount    => ( is => 'rw' );
has country_code => ( is => 'rw' );
has _parser      => ( is => 'rw' );

around BUILDARGS => sub {
  my ( $orig, $class, @args ) = @_;
  return { country_code => $args[0] } if @args == 1 && !ref $args[0];
  return $class->$orig(@args);
};

sub start_document {
  my ($self) = @_;
  $self->eventList( [] );
  $self->errorList( [] );
}

sub end_document {
  my ($self) = @_;
  my $report = $self->_parser->{output};
  $report->{eventList} = $self->eventList;
  $report->{errorList} = $self->errorList;
} ## end sub end_document

sub start_element {
  my ( $self, $element ) = @_;

  if ( $element->{Name} eq 'event' ) {
    $self->currentEvent( {} );
  } elsif ( $element->{Name} eq 'rating' ) {
    if ( exists $element->{Attributes}{rating} && $element->{Attributes}{rating} =~ m/(\d+)/ ) {
      $self->{currentEvent}{parental_rating} = $1;
    }
    if ( exists $element->{Attributes}{country_code} && uc( $element->{Attributes}{country_code} ) eq 'SK' ) {

      # detect Slovak country and convert to 3 letter ISO3166
      $self->{currentEvent}{country_code} = 'SVK';
    } elsif ( $self->{country_code} ) {
      $self->{currentEvent}{country_code} = $self->{country_code};
    }
  } ## end elsif ( $element->{Name} ...)

  $self->currentData('');
} ## end sub start_element

sub characters {
  my ( $self, $element ) = @_;
  $self->currentData( $self->currentData . $element->{Data} );
}

sub decodeTime {
  my ( $self, $time ) = @_;

  my $utc = try {

    # decode ISO 8601 formatted datetime "2025-07-24T19:00:00Z"
    if ( $time =~ m/^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})Z/ ) {
      my $date = $1;
      my ( $hour, $min, $seconds ) = ( $2, $3, $4 );
      my $afterMidnight = 0;

      if ( $hour >= 24 ) {
        $afterMidnight = $hour - 23;
        $hour          = 23;
      }

      my $epoch = Time::Piece->strptime( "$date$\T$hour:$min:$seconds", "%Y-%m-%dT%H:%M:%S" )->epoch;
      return $epoch + $afterMidnight * ONE_HOUR;
    } ## end if ( $time =~ m/^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})Z/)
    die;
  } catch {
    say @_;
    $self->_error("Invalid date/time format [$time] at line $self->{linecount}");
    return;
  };
  return $utc;
} ## end sub decodeTime

sub end_element {
  my ( $self, $element ) = @_;
  my $value = $self->{currentData};
  my $event = $self->{currentEvent};

  $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

  my %handlers = (
    "start_time" => sub { $event->{start}      = $self->decodeTime($value) },
    "end_time"   => sub { $event->{stop}       = $self->decodeTime($value) },
    "title"      => sub { $event->{title}      = $value },
    "epi_title"  => sub { $event->{subtitle}   = $value },
    "anotation"  => sub { $event->{synopsis}   = $value },
    "season"     => sub { $event->{season}     = $value },
    "epi_number" => sub { $event->{epi_number} = $value },
    "event"      => sub {
      my @missing;
      push( @missing, "start" ) unless defined $event->{start};
      push( @missing, "stop" )  unless defined $event->{stop};
      push( @missing, "title" ) unless defined $event->{title};

      if (@missing) {
        $self->_error( "Missing or incorrect data [" . join( ' ', @missing ) . "] at line " . $self->{linecount} );
        return;
      }

      # add season/episode prefix
      if ( exists $event->{season} ) {
        my $prefix = '';
        if ( exists $event->{epi_number} ) {
          $prefix = $event->{season} . '/' . $event->{epi_number};
        } else {
          $prefix = $event->{season};
        }
        if ( $event->{subtitle} ) {
          $event->{subtitle} = "$prefix - " . $event->{subtitle};
        } else {
          $event->{subtitle} = $prefix;
        }
      } ## end if ( exists $event->{season...})

      delete( @$event{qw( season epi_number )} );

      # push to final array
      push( $self->{eventList}->@*, $event );
      delete $self->{currentEvent};
    }
  );

  $handlers{ $element->{Name} }->() if exists $handlers{ $element->{Name} };
} ## end sub end_element

sub set_document_locator {
  my ( $self, $params ) = @_;
  $self->_parser( $params->{'Locator'} );
}

sub _error {
  my $self = shift;

  push( $self->{errorList}->@*, sprintf( shift, @_ ) );
}

=head1 AUTHOR

This software is copyright (c) 2026 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
