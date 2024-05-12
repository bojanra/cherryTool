package cherryEpg::Parser::MediaCSV;

use 5.024;
use utf8;
use Moo;
use Time::Piece;
use Time::Seconds;
use Try::Tiny;
use DateTime;

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

  my $data = try {
    open( my $fh, '<:encoding(UTF-8)', $self->{source} ) || return;
    local $/;
    return <$fh>;
  };

  if ( !$data ) {
    $self->error("File empty");
    return $report;
  }

  # remove all carriage return
  $data =~ s/\r//g;

  # remove \n inside "" - text field
  $data =~ s/(,"[^"]*)(\n)([^"]*",)/$1 $3/g;

  my @content = split( /\n/, $data );

  my $rowCounter = 0;
  my @columnName;

  foreach my $line (@content) {
    $rowCounter += 1;
    chomp $line;
    $line =~ s/\n/ /g;

    $line =~ s/^,/"",/;     # insert empty content
    $line =~ s/,,/,"",/g;
    $line =~ s/,,/,"",/g;

    # split by fields
    my (@argList) = $line =~ m/("[^"]+"|[^,]+)(?:,\s*)?/g;

    # get column names
    if ( $rowCounter == 1 && !@columnName ) {
      @columnName = @argList;
      next;
    }

    # extract field content and generate hash
    my %field;
    foreach my $i ( 0 .. $#columnName ) {
      my $value = $argList[$i];

      # p $line if ! $value;
      $value =~ s/"//g;
      $field{ $columnName[$i] } = $value;
    } ## end foreach my $i ( 0 .. $#columnName)

    my $event;

    $event->{start} = try {
      my $start = $field{start_date} . ' ' . $field{start_time};

      # 30/05/24 12:30:00
      return gmtime->strptime( $start, "%d/%m/%y %H:%M:%S" )->epoch(),
    };

    $event->{stop} = try {
      my $stop = $field{end_date} . ' ' . $field{end_time};

      my $end = gmtime->strptime( $stop, "%d/%m/%y %H:%M:%S" )->epoch();

      # seems to be a bug in input data
      if ( $end < $event->{start} && $field{end_time} eq "00:00:00" ) {
        $end += ONE_DAY;
      }
    };

    $event->{title}    = $field{title};
    $event->{synopsis} = $field{description};

    # check if all event data is complete and valid
    my @missing;
    push( @missing, "start" ) unless defined $event->{start};
    push( @missing, "title" ) unless defined $event->{title};

    if ( scalar @missing > 0 ) {
      $self->error( "Missing or incorrect input data in line %i: %s", $rowCounter, join( ' ', @missing ) );
      next;
    }

    push( @{ $report->{eventList} }, $event );
  } ## end foreach my $line (@content)

  return $report;
} ## end sub parse

=head1 AUTHOR

This software is copyright (c) 2024 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;
