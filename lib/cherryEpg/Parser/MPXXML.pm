package cherryEpg::Parser::MPXXML;

use 5.024;
use utf8;
use Moo;
use XML::Parser::PerlSAX;
use Try::Tiny;

extends 'cherryEpg::Parser';

our $VERSION = '0.38';

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

  my $handler = MPXXMLHandler->new();
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

  return $report;
} ## end sub parse

package MPXXMLHandler;
use Moo;
use Time::Piece;
use Time::Seconds;

has eventList    => ( is => 'rw', default => sub { [] } );
has errorList    => ( is => 'rw', default => sub { [] } );
has currentEvent => ( is => 'rw' );
has currentData  => ( is => 'rw' );
has rawText      => ( is => 'rw' );
has linecount    => ( is => 'rw' );
has _parser      => ( is => 'rw' );

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

  if ( $element->{Name} eq 'Broadcast' ) {
    $self->currentEvent( {} );
  } elsif ( $element->{Name} eq 'ExtraTime' ) {
    $self->currentEvent->{ExtraTime} = 1;
  } elsif ( $element->{Name} eq 'Text' ) {
    $self->rawText( {} );
  }

  $self->currentData('');
} ## end sub start_element

sub characters {
  my ( $self, $element ) = @_;
  $self->currentData( $self->currentData . $element->{Data} );
}

sub decodeTime {
  my ( $self, $time ) = @_;
  if ( $time =~ m/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\+\d{2}):(\d{2})/ ) {
    return Time::Piece->strptime( $1 . $2, "%Y-%m-%dT%H:%M:%S%z" )->epoch;
  } else {
    $self->_error("Invalid date/time format [$time] at line $self->{linecount}");
    return;
  }
} ## end sub decodeTime

sub end_element {
  my ( $self, $element ) = @_;
  my $value = $self->{currentData};
  my $event = $self->{currentEvent};

  $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

  my %handlers = (
    "StartTime" => sub { $event->{start}         = $self->decodeTime($value) unless $event->{ExtraTime} },
    "EndTime"   => sub { $event->{stop}          = $self->decodeTime($value) unless $event->{ExtraTime} },
    "Title"     => sub { $event->{title}         = $value },
    "Type"      => sub { $self->{rawText}{type}  = $value },
    "Value"     => sub { $self->{rawText}{value} = $value },
    "Text"      => sub {
      $event->{subtitle} = $self->{rawText}{value}
          if $self->{rawText}{type} eq "Short";
    },
    "ExtraTime" => sub { $event->{ExtraTime} = 0 },
    "Broadcast" => sub {
      my @missing;
      push( @missing, "start" ) unless defined $event->{start};
      push( @missing, "stop" )  unless defined $event->{stop};
      push( @missing, "title" ) unless defined $event->{title};

      if (@missing) {
        $self->_error( "Missing or incorrect data [" . join( ' ', @missing ) . "] at line " . $self->{linecount} );
        return;
      }

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

This software is copyright (c) 2025 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
