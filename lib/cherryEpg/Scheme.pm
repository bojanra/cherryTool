package cherryEpg::Scheme;

use 5.010;
use utf8;
use Moo;
use strictures 2;
use Try::Tiny;
use Path::Class;
use File::Basename;
use YAML::XS;
use Spreadsheet::Read qw( row ReadData);
use Data::Validate::IP qw(is_ipv4);
use Sys::Hostname;
use File::Slurp;
use File::stat;
use Time::Piece;
use open ':std', ':encoding(utf8)';

=head3 readXLS( $path )

Read the $path in XLS format and do basic validation.
Return raw data hash. 

=cut

sub readXLS {
    my ( $self, $path ) = @_;

    # raw scheme data from imported file
    my $raw = {
        channel      => [],
        eit          => {},
        target       => undef,
        source       => {},
        countIgnored => 0,
        extendedSID  => 0,
        nomesh       => 0,
    };

    $self->{raw}       = $raw;
    $self->{errorList} = [];
    $self->{scheme}    = {};

    if ( !-e $path ) {
        $self->error("Compiling failed. Cannot open input file [$path]");
        return $raw;
    }

    my $isServiceSheet = 0;
    my $isEitSheet     = 0;

    my $eBook = ReadData( $path, parser => "xls" );

    my $allSheets = $eBook->[0]{sheet};

    # parse CONF sheet first
    if ( exists $allSheets->{CONF} ) {
        $self->parseConfSheet( $eBook, 'CONF' );
    }

    foreach my $sheetName ( keys %$allSheets ) {

        next if $sheetName eq 'CONF';

        for ($sheetName) {
            /^SERVICE$/ && do {
                $isServiceSheet = 1;
                $self->parseServiceSheet( $eBook, $sheetName );
                last;
            };
            /^EIT/ && do {
                $isEitSheet = 1;
                $self->parseEITSheet( $eBook, $sheetName );
                last;
            };
            say "Cannot parse sheet [$_]";
        } ## end for ($sheetName)
    } ## end foreach my $sheetName ( keys...)

    $self->error("Missing [SERVICE] sheet") if !$isServiceSheet;
    $self->error("Missing [EIT] sheet")     if !$isEitSheet;

    # read input file as binary and insert in report
    my $blob = read_file($path);

    # extract just filename
    my ($filename) = fileparse($path);

    my $t = localtime( stat($path)->mtime );

    $raw->{source} = {
        filename => $filename,
        blob     => $blob,
        mtime    => $t->datetime
    };

    return $raw;
} ## end sub readXLS

=head3 set( $scheme )

Set object scheme to $scheme.
Return $scheme 

=cut

sub set {
    my ( $self, $scheme ) = @_;
    $self->{raw}       = {};
    $self->{errorList} = [];
    $self->{scheme}    = $scheme;

    return $scheme;
} ## end sub set

=head3 readYAML( $path )
=head3 readYAML( $yaml )

Read the $path in YAML format or from $yaml string.
Return reference to $scheme 

=cut

sub readYAML {
    my ( $self, $arg ) = @_;
    $self->{raw}       = {};
    $self->{errorList} = [];
    $self->{scheme}    = {};

    my $scheme;

    if ( $arg =~ m/^--/s ) {

        # we have a yaml string
        $scheme = YAML::XS::Load($arg);
    } else {

        # or a path/file
        my $path = $arg;

        if ( $path =~ /\.(yml|yaml)$/ ) {

            # seems to be a yaml configuration
            $scheme = YAML::XS::LoadFile($path);

            return unless $scheme;

        } ## end if ( $path =~ /\.(yml|yaml)$/)
        else {
            $self->error("Unknown scheme file format [$path]");
        }
    } ## end else [ if ( $arg =~ m/^--/s )]

    $self->{scheme} = $scheme;

    return $scheme;
} ## end sub readYAML

=head3 writeYAML( $path)
=head3 writeYAML( )

Export scheme to $path in yaml format and return 1 on success.
Return scheme data as string if no filename defined.

=cut

sub writeYAML {
    my ( $self, $path ) = @_;

    $YAML::XS::QuoteNumericStrings = 0;

    # remove temporary stuff
    delete $self->{scheme}->{isValid};

    if ($path) {
        YAML::XS::DumpFile( $path, $self->{scheme} );
        return 1;
    } else {
        return YAML::XS::Dump( $self->{scheme} );
    }
} ## end sub writeYAML

=head3 parseServiceSheet(  )

Columns in SERVICE sheet:
serviceName, tsid, sid, onid, maxsegments, codepage, language, grabber->source, grabber->update, parser, parser option, XMLTV ID,  comment
0            1     2    3     4            5         6         7                8                9       10             11         12

Ignore row that contains text IGNORESERVICE anywhere

=cut

sub parseServiceSheet {
    my ( $self, $eBook, $sheetName ) = @_;
    my $raw = $self->{raw};

#say YAML::XS::Dump $raw;
    my $allSheets = $eBook->[0]{sheet};
    my $sheet     = $eBook->[ $allSheets->{$sheetName} ];

    foreach my $rowCounter ( 1 .. $sheet->{maxrow} ) {

        # get cells from row
        my $country = "";
        my @field   = Spreadsheet::Read::row( $sheet, $rowCounter );
        if ( scalar(@field) < 11 ) {
            $self->error("Not enough columns in row [$sheetName:$rowCounter]");
            next;
        }

        # skip column name row
        next if $rowCounter == 1;

        my $skipRow = 0;

        # remove leading and trailing spaces, ', "
        foreach (@field) {
            next if !defined;
            s/^[\s'"]+//;
            s/[\s'"]+$//;

            # ignore row if somewhere IGNORESERVICE
            if (m/IGNORESERVICE/) {
                $skipRow = 1;
            }
        } ## end foreach (@field)

        if ($skipRow) {
            $raw->{countIgnored} += 1;
            next;
        }

        # check for name
        if ( !$field[0] or $field[0] eq "" ) {
            $self->error("Service name missing in row [$sheetName:$rowCounter]");
            next;
        }

        # check for parser
        if ( !$field[9] or $field[9] eq "" ) {
            $self->error("No parser in row [$sheetName:$rowCounter]");
            next;
        }

        # tsid, sid and onid must be numbers
        if (   $field[1] !~ m|^\d+$|
            or $field[2] !~ m|^\d+$|
            or $field[3] !~ m|^\d+$| ) {
            $self->error("TSID, SID or ONID are not numbers in row [$sheetName:$rowCounter]");
            next;
        } ## end if ( $field[1] !~ m|^\d+$|...)

        # segments must be numbers
        if ( $field[4] !~ m|^\d+$| ) {
            $self->error("Segments is not number in row [$sheetName:$rowCounter]");
            next;
        }

        # codepage
        if ( !$field[5] or $field[5] eq "" ) {
            $self->error("Codepage not defined [$sheetName:$rowCounter]");
            next;
        }

        # language
        if ( !$field[6] or $field[6] !~ m/^[a-z]{3}$/i ) {
            $self->error("Incorrect language code [$sheetName:$rowCounter]");
            next;
        }

        # check for source
        if ( !$field[7] or $field[7] eq "" ) {
            $self->error("URL missing in row [SERVICE:$rowCounter]");
            $field[7] = "";
            next;
        }

        # workaround
        my $source = $field[7];
        $source =~ s/^web:/http:/i;

        # webgrabber build url from XMLTV id
        if ( $source eq "rsync://wg+/" ) {
            if ( $field[11] ) {
                $source .= $field[11] . '.xml';
            } else {
                $self->error("Parser option for WebGrab+ source missing in row [$sheetName:$rowCounter]");
                $source = "";
            }
        } ## end if ( $source eq "rsync://wg+/")

        my $sid     = $raw->{extendedSID} ? ( ( $field[1] << 16 ) + $field[2] ) : $field[2];
        my $service = {
            sid         => $sid,
            name        => $field[0],
            tsid        => $field[1],
            onid        => $field[3],
            codepage    => $field[5],
            maxsegments => $field[4],
            grabber     => {
                days   => 7,
                update => $field[8],
                url    => $source,
            },
            language => $field[6],
            parser   => $field[9] . ( $field[10] ? '?' . $field[10] : '' )
        };
        push( @{ $raw->{serviceList} }, $service );

    } ## end foreach my $rowCounter ( 1 ...)
} ## end sub parseServiceSheet

=head3 parseEITSheet(  )

Columns in EIT sheet:
TSID	IP                Port    PID    exclude SID   option
1       udp://224.0.0.1   5500    18     35,79,90      PCR,TDT

=cut

sub parseEITSheet {
    my ( $self, $eBook, $sheetName ) = @_;
    my $raw = $self->{raw};

    my $allSheets = $eBook->[0]{sheet};
    my $sheet     = $eBook->[ $allSheets->{$sheetName} ];

    foreach my $rowCounter ( 1 .. $sheet->{maxrow} ) {

        # get cells from row
        my @field = Spreadsheet::Read::row( $sheet, $rowCounter );
        my %exclude;
        my %option;
        if ( scalar(@field) < 4 ) {
            $self->error("Not enough columns in row [$sheetName:$rowCounter]");
            next;
        }

        # skip column name row
        next if !$field[0] or $field[0] =~ m/tsid/i or $rowCounter == 1;

        # remove leading and trailing spaces, ', "
        foreach (@field) {
            next if !defined;
            s/^[\s'"]+//;
            s/[\s'"]+$//;
        }

        # tsid, port and pid must be numbers
        if (   $field[0] !~ m|^\d+$|
            or $field[2] !~ m|^\d+$|
            or $field[3] !~ m|^\d+$| ) {
            $self->error("TSID, port or PID are not numbers in row [$sheetName:$rowCounter]");
            next;
        } ## end if ( $field[0] !~ m|^\d+$|...)

        # check ip format
        if ( !is_ipv4( $field[1] ) ) {
            $self->error("IP has incorrect format in row [$sheetName:$rowCounter]");
            next;
        }

        # check exclude list
        if ( $field[4] and $field[4] ne "" ) {
            my @list   = split( / *, */, $field[4] );    # implicit remove spaces
            my $listOk = 1;
            foreach (@list) {
                if ( !m/^\d+$/ ) {
                    $self->error("Incorrect exclude list format in row [$sheetName:$rowCounter]");
                    $listOk = 0;
                    last;
                }
            } ## end foreach (@list)

            # map list to hash
            if ($listOk) {
                @exclude{@list} = (1) x @list;
            }
        } ## end if ( $field[4] and $field...)

        # map elements in option field to keys
        if ( $field[5] and $field[5] ne "" ) {
            my @list = split( / *, */, $field[5] );    # implicit remove spaces
            foreach (@list) {
                my ( $key, $value ) = split(/ *= */);
                $option{$key} = defined $value ? $value : 1;
            }
        } ## end if ( $field[5] and $field...)

        my $eit = {
            tsid    => $field[0],
            output  => 'udp://' . $field[1] . ':' . $field[2],
            pid     => $field[3],
            exclude => \%exclude,
            option  => \%option,
            comment => ''
        };

        push( @{ $raw->{eit}{$sheetName} }, $eit );

    } ## end foreach my $rowCounter ( 1 ...)
} ## end sub parseEITSheet

=head3 parseConfSheet(  )

Columns in CONF sheet:
option   value

=cut

sub parseConfSheet {
    my ( $self, $eBook, $sheetName ) = @_;
    my $raw = $self->{raw};

    my $allSheets = $eBook->[0]{sheet};
    my $sheet     = $eBook->[ $allSheets->{$sheetName} ];

    foreach my $rowCounter ( 1 .. $sheet->{maxrow} ) {

        # get cells from row
        my @field = Spreadsheet::Read::row( $sheet, $rowCounter );

        # skip lines with empty first cell
        next if !defined $field[0];

        # skip column name row
        next if defined $field[0] && [0] =~ m/option/i or $rowCounter == 1;

        # remove leading and trailing spaces, ', "
        foreach (@field) {
            next if !defined;
            s/^[\s'"]+//;
            s/[\s'"]+$//;
        }

        if ( $field[0] =~ m /nomesh/i ) {
            $raw->{nomesh} = $field[1] ? 1 : 0;
        } elsif ( $field[0] =~ m /xsid/i ) {
            $raw->{extendedSID} = $field[1] ? 1 : 0;
        }

    } ## end foreach my $rowCounter ( 1 ...)
} ## end sub parseConfSheet

=head3 build( $target )

Validate raw data and build the final scheme for importing.
If no target defined use system hostname.
Return $scheme

=cut

sub build {
    my ( $self, $target ) = @_;

    $target = $target // hostname;
    my $raw    = $self->{raw};
    my $scheme = {
        eit     => [],
        rule    => [],
        channel => []
    };
    my $_target = '';

    # check if EIT for target exists
    if ( exists $raw->{eit}{ "EIT|" . $target } ) {
        $scheme->{target} = $target;
        $_target = "EIT|" . $target;
    } elsif ( exists $raw->{eit}{EIT} ) {
        $scheme->{target} = undef;
        $_target = "EIT";
    }

    # make hash of all TSID defined in output
    my $tsHash = {};
    my $output = {};    # key is ip:port:pid

    foreach my $eit ( @{ $raw->{eit}{$_target} } ) {
        my $tsid = $eit->{tsid};
        if ( exists $tsHash->{$tsid} ) {
            $self->error("Duplicate TS output [$tsid]");
        } else {
            $tsHash->{$tsid} = $eit;
            my $o = $eit->{output} . ':' . $eit->{pid};
            if ( exists $output->{$o} ) {
                $self->error("Cannot use same output for two TS [$tsid,$output->{$o}]");
            } else {
                $output->{$o} = $tsid;
            }
        } ## end else [ if ( exists $tsHash->{...})]
    } ## end foreach my $eit ( @{ $raw->...})

    # make hash of all TSID used in service sheet
    my $tsByService = {};

    # and hash of services by channel_id
    my $serviceHash = {};

    foreach my $service ( @{ $raw->{serviceList} } ) {
        my $tsid = $service->{tsid};

        # check for duplicate
        if ( exists $serviceHash->{ $service->{sid} } ) {
            $self->error("Duplicate SID [$service->{sid}]");
            next;
        } else {
            $serviceHash->{ $service->{sid} } = 1;
        }

        if ( !exists $tsByService->{$tsid} ) {
            $tsByService->{$tsid} = {};

            # check if the output for this TSID is defined
            if ( !exists $tsHash->{$tsid} ) {
                $self->error("Output for TSID [$tsid] not defined");
            }
        } ## end if ( !exists $tsByService...)
        $tsByService->{$tsid}{ $service->{sid} } = $service;
    } ## end foreach my $service ( @{ $raw...})

    # build list of actual, other
    foreach my $tsid ( keys %$tsHash ) {
        $tsHash->{$tsid}{tables}{actual} = [];
        $tsHash->{$tsid}{tables}{other}  = [];

        foreach my $service ( @{ $raw->{serviceList} } ) {

            # check exclude and skip
            # we check only by sid not by onid|tsid|sid TODO
            my $sid = $service->{sid};
            next if exists $tsHash->{$tsid}{exclude}{$sid};

            if ( $service->{tsid} == $tsid ) {
                push( @{ $tsHash->{$tsid}{tables}{actual} }, $service );
            } else {
                next if ( $tsHash->{$tsid}{option}{NOMESH} || $raw->{nomesh} );
                push( @{ $tsHash->{$tsid}{tables}{other} }, $service );
            }
        } ## end foreach my $service ( @{ $raw...})
    } ## end foreach my $tsid ( keys %$tsHash)

    # generate eit & rules
    my $eitCounter = 0;
    foreach my $tsid ( sort { $a <=> $b } keys %$tsHash ) {

        $eitCounter += 1;
        my $eit = {
            eit_id => $eitCounter,
            pid    => $tsHash->{$tsid}{pid} + 0,    # must be numeric
            output => $tsHash->{$tsid}{output},
            option => $tsHash->{$tsid}{option}
        };
        push( @{ $scheme->{eit} }, $eit );

        # list both (actual, other)
        foreach my $table ( keys %{ $tsHash->{$tsid}{tables} } ) {

            # just build a rule
            foreach my $service ( @{ $tsHash->{$tsid}{tables}{$table} } ) {

                # get the original id
                my $realServiceId = $service->{sid} & 0xffff;
                my $rule          = {
                    actual              => ( $table eq 'actual' ? 1 : 0 ),
                    channel_id          => $service->{sid},
                    eit_id              => $eitCounter,
                    comment             => '',
                    original_network_id => $service->{onid},
                    service_id          => $realServiceId,
                    transport_stream_id =>
                        ( exists $tsHash->{$tsid}{option}{TSID} ? $tsHash->{$tsid}{option}{TSID} : $service->{tsid} ),
                };
                push( @{ $scheme->{rule} }, $rule );
            } ## end foreach my $service ( @{ $tsHash...})
        } ## end foreach my $table ( keys %{...})
    } ## end foreach my $tsid ( sort { $a...})

    my @sortedRule =
        sort {
               $a->{transport_stream_id} <=> $b->{transport_stream_id}
            or $b->{actual}              <=> $a->{actual}
            or $a->{channel_id}          <=> $b->{channel_id}
        } @{ $scheme->{rule} };

    $scheme->{rule} = \@sortedRule;

    # copy sorted list of channels to scheme
    my @sortedChannel =
        map { delete $_->{tsid}; delete $_->{onid}; $_->{channel_id} = $_->{sid}; delete $_->{sid}; $_ }
        sort { $a->{sid} <=> $b->{sid} } @{ $raw->{serviceList} };

    # map channels to scheme
    $scheme->{channel} = \@sortedChannel;

    $scheme->{isValid} = scalar @{ $self->error } == 0;

    # copy raw part
    $scheme->{source} = $raw->{source};

    $self->{scheme} = $scheme;
    return $scheme;
} ## end sub build

=head3 error( @args )

Add @arg (sprintf style) to errorList.
Return errorList when called without argument.

=cut

sub error {
    my ( $self, @arg ) = @_;

    if ( scalar @arg ) {
        push( @{ $self->{errorList} }, sprintf( shift @arg, @arg ) );
    } else {
        return $self->{errorList};
    }
} ## end sub error

=head1 AUTHOR

This software is copyright (c) 2019 by Bojan Ramšak

=head1 LICENSE

This file is subject to the terms and conditions defined in
file 'LICENSE', which is part of this source code package.

=cut

1;

__END__
channel:
- channel_id: 1
  codepage: ISO-8859-2
  segments: 3
  grabber:
    days: 7
    update: daily
    url: http://api.rtvslo.si/spored/list/tvs1/%Y-%m-%d
  language: slv
  name: SLO 1
  parser: RtvSloJSON
eit:
- eit_id: 1
  pid: 18
  output: udp://239.2.100.1:5500
- eit_id: 2
  pid: 18
  output: udp://239.2.100.2:5500
- actual: 1
  channel_id: 1
  comment: ''
  eit_id: 1
  maxsegments: 56
  original_network_id: 8897
  service_id: 1
  transport_stream_id: 1
