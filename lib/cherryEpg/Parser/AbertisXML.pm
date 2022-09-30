package cherryEpg::Parser::AbertisXML;

use 5.024;
use utf8;
use Moo;
use XML::Parser::PerlSAX;

extends 'cherryEpg::Parser';

our $VERSION = '0.11';

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

    my $handler = AbertisXMLHandler->new();
    my $parser  = XML::Parser::PerlSAX->new(
        Handler => $handler,
        output  => $report
    );

    $parser->parse( Source => { SystemId => $self->{source} } );

    return $report;
} ## end sub parse

package AbertisXMLHandler;
use strict;
use warnings;
use Time::Piece;
use Carp qw( croak );

sub new {
    my $this  = shift;
    my $class = ref($this) || $this;
    my $self  = {};

    bless( $self, $class );
    return $self;
} ## end sub new

sub start_document {
    my ($self) = @_;

    # this will be the list of events
    $self->{eventList} = [];

    # and the possible error list
    $self->{errorList} = [];
} ## end sub start_document

sub end_document {
    my ( $self, $element ) = @_;

    $self->{report}            = $self->{'_parser'}->{output};
    $self->{report}{eventList} = $self->{eventList};
    $self->{report}{errorList} = $self->{errorList};
    $self->{report}{channel}   = $self->{Service};
} ## end sub end_document

sub start_element {
    my ( $self, $element ) = @_;

    if ( $element->{Name} eq "Event" ) {
        my $event = {
            start    => undef,
            duration => undef
        };

        # save the start and duration
        if ( $element->{Attributes}{beginTime} ) {
            $event->{start} = localtime->strptime( $element->{Attributes}{beginTime}, "%Y%m%d%H%M%S" )->epoch;
        }
        if ( $element->{Attributes}{duration} ) {
            $event->{duration} = $element->{Attributes}{duration};
        }

        $self->{currentEvent} = $event;
    } ## end if ( $element->{Name} ...)

    $self->{currentData} = "";
} ## end sub start_element

sub characters {
    my ( $self, $element ) = @_;

    $self->{currentData} .= $element->{Data};
}

sub end_element {
    my ( $self, $element ) = @_;
    my $value = $self->{currentData};
    my $event = $self->{currentEvent};

    $self->{linecount} = $self->{_parser}->location()->{'LineNumber'};

SWITCH: for ( $element->{Name} ) {
        $_ eq "Event" && do {

            # add the event to the list
            $self->addEvent();
            return;
        };
        $_ eq "Name" && do {
            return if $value eq '';

            $event->{title} = $value;
            return;
        };
        /ShortDescription/ && do {
            return if $value eq '';

            $event->{subtitle} = $value;
            return;
        };
        /Description/ && do {
            return if $value eq '';

            $event->{synopsis} = $value;
            return;
        };
    } ## end SWITCH: for ( $element->{Name} )
    return;
} ## end sub end_element

sub set_document_locator {
    my ( $self, $params ) = @_;
    $self->{'_parser'} = $params->{'Locator'};
}

sub _error {
    my $self = shift;

    push( @{ $self->{errorList} }, sprintf( shift, @_ ) );
}

sub addEvent {
    my $self  = shift;
    my $event = $self->{currentEvent};

    # check if all event data is complete and valid
    my @missing;
    push( @missing, "start" ) unless defined $event->{start};
    push( @missing, "title" ) unless defined $event->{title};

    if ( scalar @missing > 0 ) {
        $self->_error( "Missing or incorrect input data [" . join( ' ', @missing ) . "] line " . $self->{linecount} );
        return;
    }

    # push to final array
    push( @{ $self->{eventList} }, $event );

    return 1;
} ## end sub addEvent

=head1 AUTHOR

This software is copyright (c) 2021 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
