package cherryEpg::Parser::MPXXML;

use 5.024;
use utf8;
use Moo;
use XML::Parser::PerlSAX;
use Try::Tiny;

extends 'cherryEpg::Parser';

our $VERSION = '0.41';

sub BUILD {
  my ( $self, $arg ) = @_;

  $self->{report}{parser} = __PACKAGE__;
}

=head3 parse( $parserOption)

Do the file processing and return a reference to hash with keys
- errorList => array with troubles during parsing
- eventList => array of events found

The $parserOption is used to set the working mode:
undefined or 0 - classic mode   Short Text -> subtitle
1              - alternate mode Short Text -> synopsis
2              - combi mode     Short Text -> synopsis
                           Very Short Text -> subtitle
=cut

sub parse {
  my ( $self, $parserOption ) = @_;
  my $report = $self->{report};

  # get mode
  my ($mode) = $parserOption // 0;

  my $handler = MPXXMLHandler->new( mode => $mode );
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
has mode         => ( is => 'ro', default => sub {0} );

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
      if ( $self->{rawText}{type} eq "Short" ) {
        if ( $self->mode == 1 || $self->mode == 2 ) {
          $event->{synopsis} = $self->{rawText}{value};
        } else {
          $event->{subtitle} = $self->{rawText}{value};
        }
      } elsif ( $self->{rawText}{type} eq "VeryShort" && $self->mode == 2 ) {
        $event->{subtitle} = $self->{rawText}{value};
      }
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
