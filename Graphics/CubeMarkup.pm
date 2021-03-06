=head1 CubeMarkup

Object to handle markup of a data cube with pixel locations of features, using Gnuplot as a backend.

(Should probably use Prima, but I understand Gnuplot better)

=head1 METHODS

=cut


use PDL::NiceSlice;

package CubeMarkup;

use PDL::Graphics::Gnuplot;

=head2 new

=for ref 

Constructor accepts a PDL data cube and some plot options

You pass in a hash containing everything.  Hash keys are:

=over 3

=item * data

Array ref containing PDLS with the data to plot and mark up

=item * alt_data

(optional) array ref containing an alternate representation of the main data.
If present, you can press 'd' during markup to swap between data sets.

=item * plot_options

Gnuplot plot options hash (optional)

=item * markup

Prior markup, or nothing

=item * frame

The frame to start at (default 0)

=item * window

A gnuplot plot interface to use (or nothing to define a default window)

=back

=cut

use overload '""' => \&_stringify;

sub new {
    my $me = {};
    my $class = shift;
    my %h = @_;
    my $h = \%h;
    
    $me->{data}         = $h->{data};
    $me->{alt_data}     = $h->{alt_data};
    die "Data must be an array ref or PDL" unless(ref($h->{data}) eq 'ARRAY' or ref($h->{data}) eq 'PDL');
    $me->{plot_options} = $h->{p_opt} // {};
    $me->{markup} = $h->{markup} // [];
    $me->{window} = $h->{window} // gpwin(size=>[9,9],enhanced=>1);
    $me->{frame} = $h->{frame} // 0;
    $me->{nframes} = ( ref($me->{data}) eq 'ARRAY' ) ? 0+@{$me->{data}} : $me->{data}->dim(2);

    $me->{render_points} = 1;
    $me->{render_paths} = 1;

    return bless($me,$class);
}

=head2 cutout

=for ref

You provide a list of locations of a datum, a width and size of a
cutout, and a location within the cutout of the datum.

The rendered portions of the movie are cut out from around the datum
for each frame.

The locations are given in pixel coordinates. 

You feeed in a hash ref containing the following:

=over 3

=item size

This is a 2-PDL or an array ref, with (width,height) of the cutout, in
pixels

=item xy

If specified, this is a 2-PDL or list ref, with (x,y) of the point of
interest ("datum") inside the cutout, after cutting.  If you don't 
give one, it defaults to the middle of the cutout.

=item loc

This must be specified.  It can be:

=over 3

=item * 

A 2-PDL or array ref, containing pixel coordinates of the datum in 
the original images, for the whole dataset;

=item * 

A 2xN-PDL, containing pixel coordinates of the datum for each frame of
the original data set;

=item * 

A 3xM-PDL, containing (x,y,t) triplets for tiepoints.  In this case,
the datum point is determined by spline interpolation between the 
supplied points.  

=back

=back


=cut
use PDL;

sub cutout {
    my $me = shift;
    my $h = shift;

    unless(defined($h)) {
	delete $me->{cutout};
	return;
    }

    unless(ref $h eq 'HASH') {
	my %h = ($h,@_);
	$h = \%h;
    }

    # Size
    die "Must specify a cutout size" unless(defined($h->{size}));
    my $size = $h->{size};
    $size = pdl($size) if(ref($size) eq 'ARRAY');
    die "Size must be a 2-array ref or PDL" unless(ref($size) eq 'PDL' and $size->nelem==2);
    $size = ($size+0.5)->floor;

    # XY: location inside the cutout of the datum
    my $cutout_xy = $h->{xy} // $size/2;
    $cutout_xy = pdl($cutout_xy) if(ref($cutout_xy) eq 'ARRAY');
    die "xy location, if specified, must be a single 2-array ref or PDL" unless(ref($cutout_xy) eq 'PDL' and $cutout_xy->nelem==2);

    # loc: location inside the image of the datum to be cut out
    die "Must specify a location in the data set" unless(defined($h->{loc}));
    my $loc = pdl($h->{loc});

    my $locbyframe;
    if($loc->nelem==2) {
	$locbyframe = $loc->dummy(2,$me->{nframes})->copy;
    } elsif( $loc->ndims==2 and $loc->dim(0)==2 and $loc->dim(1)==$me->{nframes} ) {
	$locbyframe = $loc->copy;
    } elsif( $loc->ndims==2 and $loc->dim(0)==3 ) {
	my $t = xvals($me->{nframes});
	$locbyframe = cspline_irregular($loc->((2)),$loc->(0:1)->mv(0,1), $t->(*1));
    } else {
	die "locbyframe isn't the right shape.";
    }

    my $lo = floor( $locbyframe - $cutout_xy + 0.5 );
    my $hi = $lo + $size - 1;
    $me->{cutout} = {
	size => $size,
	lo   => $lo,
	loc  => $locbyframe,
	xy   => $cutout_xy
    };
}


=head2 _stringify

=for ref

CubeMarkup objects are stringified with a few explanatory notes.

=cut


sub _stringify { 
    my $me = shift;
    my $s = "";

    $s .= "CubeMarkup: \n";
    if(defined( $me->{data} ) ) {
	if( ref($me->{data}) eq 'PDL') {
	    $s .= "\tData is a ".(join("x",$me->{data}->dims))." PDL.\n";
	} elsif( ref($me->{data}) eq 'ARRAY' ) {
	    if(ref $me->{data}->[0] eq 'PDL') {
		$s .= "\tData is a ".(0+@{$me->{data}})."-array of ".(join("x",$me->{data}->[0]->dims))."-PDLs\n";
	    } else {
		$s .= "\tData is not valid! (ARRAY ref, but first element is not a PDL)\n";
	    }
	} else {
	    $s .= "\tData is not valid! (non-ARRAY, non-PDL ref, or Perl scalar)";
	}
    } else {
	$s .= "\tData is undefined!\n";
    }

    $s .= "\tCurrent frame is $me->{frame}\n";
}


=head2 render

=for ref

Renders the currently selected frame (in the 'frame' field).

Accepts a hash that indicates whether certain things are to be rendered or no.

The hash can meaningfully contain:

=over 3

=item p_opt 

Plot options to replace the current ones

=item points

If nonzero, render current control points.

=item paths

If nonzero, render the paths of all currently defined control points, as lines.

=item frame

Set the frame number to render

=back

Control points are stored in the "tracking" field of the object.
'tracking' is a hash ref containing tracking parameters, one of which
is "paths".  "paths" is an array ref.  Each element is a PDL
containing (x,y,frame) for tiepoints for that path.

=cut


sub render {
    my $me = shift;
    my $h = shift;
    my %extra_po = ();

    if(defined($h) and ref($h) ne 'HASH') {
	my %h = ($h,@_);
	$h = \%h;
    } elsif(!defined($h)) {
	$h = {};
    }

    my $copies = {
	p_opt    =>"plot_options",
	points   =>"render_points",
	paths    =>"render_paths",
	frame    =>"frame"
    };
    for $k(keys %$copies) {
	if(exists($h->{$k})) {
	    $me->{$copies->{$k}} = $h->{$k};
	}
    }

    if(ref($h->{extra_po}) eq 'HASH') {
	for $k(keys %{$h->{extra_po}}) {
	    $extra_po{$k} = $h->{extra_po}->{$k};
	}
    }

    $me->{window}->options(%{$me->{plot_options}});

    my $frame;
    if(ref $me->{data} eq 'PDL') {
	$frame = $me->{data}->(:,:,($me->{frame}));
    } else {
	$frame = $me->{data}->[$me->{frame}];
    }
    
    my $coords;
    my $xr;
    my $yr;
    my %po;

    if($me->{cutout}) {
	my $lo = $me->{cutout}->{lo}->(:,($me->{frame}));
	my $lof = $lo->floor;
	$frame = $frame->range( $lof, $me->{cutout}->{size}, 't' );
	$coords = ndcoords($frame) + $lof;
	%po = (xr=>[$lo->at(0)-0.5,$lo->at(0)+$me->{cutout}->{size}->at(0)],
	       yr=>[$lo->at(1)-0.5,$lo->at(1)+$me->{cutout}->{size}->at(1)]);
    } else {
	$coords = ndcoords($frame);
	%po = (xr=> [-0.5,$frame->dim(0)-0.5],
	       yr=> [-0.5,$frame->dim(1)-0.5]);

    }

    
    my @plot_list = (
	
	with=>'image',
	$coords->using(0,1),
	$frame
	);

    if($me->{render_points} and defined($me->{tracking}) and ref($me->{tracking}) eq 'HASH' and exists($me->{tracking}->{paths}) and ref($me->{tracking}->{paths}) eq 'ARRAY') {
	for my $i(0..$#{$me->{tracking}->{paths}}) {
	    next if( $me->{filter}  and  $i != $me->{trace});
	    next if(ref($me->{render_points}) eq 'HASH' and !($me->{render_points}->{$i}));
	    my $xyt = $me->{tracking}->{paths}->[$i];
	    next unless(ref($xyt) eq 'PDL');

	    if($me->{render_points} >= 2) {
		push(@plot_list,
		     with=>'circles',
		     ls=>$i+1,ps=>undef,
		     $xyt->((0)),
		     $xyt->((1)),
		     ones($xyt->((0)))
		    );
	    }

	    my($min,$max) = $xyt->((2))->minmax;
	    next unless($me->{frame} >= $min and $me->{frame} <= $max);
	    $xy = cspline_irregular($xyt->((2)), $xyt->(0:1)->mv(0,1), pdl($me->{frame}));
	    if($me->{render_points} % 2) {
		push(@plot_list,
		     with=>'points',
		     ls=>$i+1,ps=>1.5,
		     legend=>"Trace $i",
		     $xy->using(0,1)
		    );
	    }

	}
    }

    if(($me->{render_trace} || $me->{render_paths}) and 
       defined($me->{tracking}) and 
       ref($me->{tracking}) eq 'HASH' and 
       exists($me->{tracking}->{paths}) and 
       ref($me->{tracking}->{paths}) eq 'ARRAY') {

	for my $i(0..$#{$me->{tracking}->{paths}}) {
	    next if( $me->{filter}  and  $i != $me->{trace});
	    next if(ref($me->{render_paths}) eq 'HASH' and !($me->{render_paths}->{$i}));

	    my $xyt = $me->{tracking}->{paths}->[$i];
	    next unless(ref($xyt) eq 'PDL');

	    my ($frmin,$frmax) = $xyt->((2))->minmax;
	    next unless( $me->{frame} >= $frmin-1 and $me->{frame} <= $frmax+1);


	    my $fdex = xvals($frmax-$frmin+1)+$frmin;
	    $xy = cspline_irregular($xyt->((2)), $xyt->(0:1)->mv(0,1), $fdex->(*1));


	    if($me->{render_paths} == 1 || ($me->{render_trace}==1  and  $i==$me->{trace})) {
		push(@plot_list,
		     with=>'dots',
		     ls=>$i+1,ps=>undef,
		     $xy->using(0,1)
		    );
	    } 
	    if($me->{render_paths} == 2 || ($me->{render_trace}==2 and $i==$me->{trace})) {
		push(@plot_list,
		     with=>'lines',
		     ls=>$i+1,ps=>undef,
		     $xy->using(0,1)
		    );
	    }
	}
    }

    $me->{window_scale} = 1.0 unless($me->{window_scale});

    my $attempts = 0;
    do {
	undef $@;
	eval {
	    if($me->{terminal}) {
		$me->{window}->output($me->{terminal},size=>[$frame->dim(0)*$me->{window_scale},$frame->dim(1)*$me->{window_scale},'px']);
	    } else {
		$me->{window}->output(size=>[$frame->dim(0)*$me->{window_scale},$frame->dim(1)*$me->{window_scale},'px']);
		$me->{terminal} = $me->{window}->{terminal};
	    }
	    $me->{window}->plot( {%po, %extra_po},
				 @plot_list,
				 {key=>'top left textcolor rgb "white"',title=>"Frame $me->{frame} of ".(0+@{$me->{data}})." (".($me->{data}->[$me->{frame}]->hdr->{'DATE-OBS'}//"NO DATE").")" });
	};
	if($@){
	    print STDERR $@;
	    $attempts++;
	    $me->{window}->restart;
	}
    } until( !$@  or  $attempts >= 3 );
}

=head2 markup_curves

=for ref

Control loop accumulates point sets.

=cut
use PDL::IO::Dumper;


sub markup_curves {
    my $me = shift;
    my $ls = 1;

    $me->{help} = 0 unless(defined($me->{help}));
    $me->{trace} = 0 unless(defined($me->{trace}));
    $me->{render_trace} = 0 unless(defined($me->{render_trace}));

    ####
    # Register actions for keystrokes.
    # Numeric keystrokes are registered with a loop below.
    my $actions = {
	## d: 'data' - swap primary and alt data
	'd' => sub { return unless(defined($me->{alt_data})); my $z = $me->{data}; $me->{data} = $me->{alt_data}; $me->{alt_data} = $z;},
	## j/k and J/K for jumping forward and backward through the path list
	'j' => sub { $me->{trace}-- if($me->{trace} > 0); },
	'J' => sub { $me->{trace} -= 10; $me->{trace} = 0 if($me->{trace} < 0);},
	'k' => sub { $me->{trace}++; },
	'K' => sub { $me->{trace} += 10; },
	'L' => sub { print "L\n"; $me->{trace} = ((defined($me->{tracking}->{paths})) ? 0+@{$me->{tracking}->{paths}} : 0);},
		     
	## Move frame Forward/backward with '<' and '>' (slow with ',' and '.')
	'.' => sub { $me->{frame}++ unless($me->{frame} >= $me->{nframes}-1); },      
	',' => sub { $me->{frame}-- unless($me->{frame} <= 0); },                     
	'>' => sub { $me->{frame}+= 10 unless($me->{frame} >= $me->{nframes}-11);},
	'<' => sub { $me->{frame}-= 10 unless($me->{frame} <= 9);},

	## Toggle points, lines, and help rendering: 'p', 'l', and 'h'
	'f' => sub { $me->{filter} = !($me->{filter}) },
	'p' => sub { $me->{render_points} = ($me->{render_points} + 1)%4; },
	'l' => sub { $me->{render_paths} =  ($me->{render_paths} + 1)%3; },
	'h' => sub { $me->{help} = !($me->{help}); },
	't' => sub { $me->{render_trace} = ($me->{render_trace} + 1)%3;},

	## Make a backup with 'b'
	'b' => sub {
	    my $fname = sprintf("tracking-backup-$$-%3.3d.pl",$me->{backup_count}); 
	    $me->{backup_count}++;
	    fdump($me->{tracking},$fname);
	    printf("Backed up tracks to $fname\n");
	},

	## Zoom window
	'+' => sub { $me->{window_scale} *= 1.1; $me->{window}->restart},
	'=' => sub { $me->{window_scale} *= 1.1; $me->{window}->restart},
	'-' => sub { $me->{window_scale} /= 1.1; $me->{window}->restart},
	'_' => sub { $me->{window_scale} /= 1.1; $me->{window}->restart},

	## Change color scale
	'[' => sub { $me->{plot_options}->{cbr}->[1] *= 1.1 if(defined($me->{plot_options}->{cbr})); },
	']' => sub { $me->{plot_options}->{cbr}->[1] /= 1.1 if(defined($me->{plot_options}->{cbr})); },

	## DEL -- delete the nearest tiepoint on the current trace
	'#008' => sub { 
	    my $h = shift;
	    my $xyt = $me->{tracking}->{paths}->[$me->{trace}];
	    return unless defined($xyt);
	    if($xyt->dim(1)==1) {
		undef $me->{tracking}->{paths}->[$me->{trace}];
		return;
	    }
	    my $t_closest = ($xyt->((2)) - $me->{frame})->abs->minimum_ind;
	    $xyt->((2),$t_closest) .= -1;
	    $me->{tracking}->{paths}->[$me->{trace}] = $xyt->(:, $xyt->((2))->qsorti)->(:,1:-1)->sever;
	}
    };

    # Distinguish up to 40 traces with keystrokes and SHIFT/CTRL.
    # This is horribly non-i18n noncompliant -- it has hand-coded
    # numeric keys without/with SHIFT (U.S. keyboards), but it's hard
    # to get gnuplot to report key independently of SHIFT/CTRL...
    my $numsub = sub { $me->{trace} = $_[1] + (($_[0]->{m} =~ m/C/) ? 20 : 0); };
    my @numkeys = split //,'0123456789)!@#$%^&*(';  
    for my $i(0..$#numkeys){
	$actions->{$numkeys[$i]} = sub { &$numsub(shift,$i); };
    }
		     
    # Event loop
    do {

	# Figure line to render at the bottom
	$s = ($me->{filter}) ? "FILT " : "     ";
	$s .= ($me->{render_points}) ? "PTS " : "    ";
	$s .=($me->{render_paths}) ? "LNS " : "    ";
	$s .= sprintf "(Trace %d of %d) ",$me->{trace},((ref($me->{tracking}->{paths}) eq 'ARRAY')?@{$me->{tracking}->{paths}}+0:0);
	$s .= $me->{help} ? " (< & > move frame; 0-9 sel. trace; L & P toggle display; mouse creates; DEL removes)" : " PRESS H FOR HELP";
	
	# Render image and read mouse
	my $at;
	if($me->{cutout}) {
	    $at = [($me->{cutout}->{lo}->(0:1,($me->{frame}))+10)->list];
	} else {
	    $at = [10,10];
	}
	print "at is ".join("x",@$at)."\n";
	$me->render(extra_po=>{label1=>[$s,at=>$at,'noenhanced','front',textcolor=>'rgb "white"']});
	$h = $me->{window}->read_mouse("");

	# Take action based on mouse/keyboard input. 
	if( length($h->{k}) && $actions->{$h->{k}} ) {
	    # Known keystroke: take appropriate action
	    &{$actions->{$h->{k}}}($h);
	} elsif( $h->{b} ) {
	    # Button press: register a tiepoint in the current trace
	    $me->{tracking} = {} unless(defined($me->{tracking}));
	    $me->{tracking}->{paths} = [] unless(defined($me->{tracking}->{paths}));

	    $xyt = $me->{tracking}->{paths}->[$me->{trace}];

	    my $newxytrow = pdl($h->{x},$h->{y},$me->{frame})->dummy(1,1);

	    if(!defined($xyt)) {
		$me->{tracking}->{paths}->[$me->{trace}] = $newxytrow;
	    } elsif(any($xyt->((2)) == $me->{frame})) {
		# replace a duplicate point
		my $row = $xyt->(:,which($xyt->((2))==$me->{frame}));
		$row .= $newxytrow;
	    } else {
		my $newxyt = $xyt->glue(1,$newxytrow);
		$me->{tracking}->{paths}->[$me->{trace}] = $newxyt->(:, $newxyt->((2))->qsorti)->sever;
	    }

	} else {
	    # Unknown keystroke: print the event record to the screen
	    print join(" ",(map { $_.":".$h->{$_} } sort keys %$h)),"\n";
	}
	# Note end condition: pressing 'q' terminates the window (non-maskable) and yields an empty event.
    } while( $h->{b} || length($h->{k}) || $h->{m} );
}

=head2 export_paths

=for usage 

 $a->markup_curves();
 @output = $a->export_paths();

=for ref

Export tracking data

You get out an array containing the traces adjusted to original movie image coordinates.

=cut

sub export_paths {
    my $me = shift;
    my $h = shift // {};
    if( defined($h) and ref($h) ne 'HASH' ) {
	my %h = ($h,@_);
	$h = \%h;
    }

    my @out = ();
    unless(defined($me->{tracking}) and ref($me->{tracking}) eq 'HASH' and ref($me->{tracking}->{paths}) eq 'ARRAY') {
	die "export_traces: no traces to export!";
    }

    for my $i(0..$#{$me->{tracking}->{paths}}) {
	if(defined($me->{tracking}->{paths}->[$i])) {
	    our $pdl = $me->{tracking}->{paths}->[$i]->copy;
	    
	    if($h->{spline}) {
		my ($min,$max) = $pdl->((2))->minmax;
		my $dex = xvals($max-$min+1)+$min;
		$pdl = cspline_irregular($pdl->((2)),$pdl->(0:1),$dex->(*1))->glue(0,$dex);
	    } 

#	    if($me->{cutout}) {
#		$pdl->(0:1) += cspline_irregular(xvals($me->{nframes}), $me->{cutout}->{lo}->mv(0,-1), $pdl->(2) );
#	    }

	    push(@out,$pdl);
	    
	} else {
	    push(@out, undef);
	}
    }

    return @out;
}

=head2 import_paths

=for usage

 $traces = frestore('traces.pl');
 $a->import_paths($traces);

=for ref

Import tracking data

You feed in a ref to an array such as export_traces produces, and it replaces the 
{tracking}->{traces} field.  The offsets are corrected into the current offset coordinates.

=cut

sub import_paths {
    my $me = shift;
    my $traces = shift;
    die "Requires an ARRAY ref" unless(ref($traces) eq 'ARRAY');

    $me->{tracking} = {};
    $me->{tracking}->{paths} = [ map { defined($_)?$_->copy:undef } @$traces ];
    
#    if($me->{cutout}) {
#	for $i(0..$#{$me->{tracking}->{paths}}) {
#	    my $pdl = $me->{tracking}->{paths}->[$i];
#	    my $pf = $pdl->((2));
#	    $pdl->(0:1) -= $me->{cutout}->{lo}->(:,$pf);
#	}
#    }
}

    

=head2 cspline_irregular - interpolate using csplines on an irregularly sampled dataset

=for usage

$out = cspline_irregular($x, $data, $xloc, $c)

=for signature

cspline_irregular( x(n), data(n), xloc(), [o]out(), $c )

=for ref

1-D spline interpolation on a dataset (threaded).  

Unlike cspline_interp, xloc is in "x units" (not array index units).
The x coordinates of the source data need to be monotonically increasing.

=cut


sub cspline_irregular {
    my $x = shift;
    my $data = shift;
    my $loc = shift;
    my $c = pdl(shift // 0);

    if($x->nelem==0) {
	barf("cspline_irregular: got an empty set of x coordinates!");
    } elsif($x->nelem==1) {
	return $data->((0));
    }

    unless( all($x->slice([1,-1]) > $x->slice([0,-2])) ) {
	barf("cspline_irregular: x coordinate must be monotonic");
    }

    my $o = PDL::my_cspline_irregular($x,$data,$loc,$c);

}

no PDL::NiceSlice;
BEGIN {`mkdir /tmp/inline-$$`;}
use Inline (PDLPP=>Config=>DIRECTORY=>"/tmp/inline-$$/");
use Inline PDLPP => <<'EOF';

pp_def('my_cspline_irregular',
	Pars=>'x(k); dat(k); xloc(); c(); [o]out();',
	Inplace=>0,
	Code=> <<'EOC'
	long i;
	long dex;
	long dexlo;
        double xlo;
        double xhi;
        double x;
	long dexhi;
        double p[4];
       double xp[4];
       long n;
       double z = asin(1.1);

       n = $SIZE(k);

       if(0 && $xloc() < $x(k=>0)   ) {
	 $out() = asin(z);
       } else if(0 && $xloc() > $x(k=>n-1)) {
	 $out() = asin(z);
       } else {

	 // dex gets the index of the first location with less than or equal X to the xloc
	 {
	   // Binary search;
	   dexlo = -1;
	   dexhi = n;
	   xlo = $x(k=>0);
	   xhi = $x(k=>n-1);
	   dex = 0;
	   while(dexlo < dexhi - 1) {
	       dex = (dexlo + dexhi)/2;
	       if(dex >= 0 && dex <= n-1) {
		 x = $x(k=>dex);
		 if(x >= $xloc()) {
		   dexhi = dex;
		   xhi = x;
		 } else {
		   dexlo = dex;
		   xlo = x;
		 }
		 if(xlo > xhi){
		     barf("Assertion failed! (Data are non-monotonic but passed monotonicity check)");
		 }
	       } else {
		 if(dex<0) {
		   dexlo = -1;
		   dexhi = 0;
		   dex = -1;
		 } else if(dex>n-1) {
		   dexlo = n-1;
		   dexhi = n;
		   dex = n-1;
		 }
	       }
	   }
	 }
	 
       // Now dexlo has the highest X value lower than the currently sought value.
       // Perform spline interpolation on an irregular grid.
       
       // Assemble an array of the four points surrounding the original.

       dex = dexlo - 1;

       for(i=0;   i<4;   i++,dex++) {
	   if(dex<0) {
	       p[i]   = $dat(k=>0);
	       xp[i]  =   $x(k=>0)   +  dex;
	   } else if(dex >= n) {
	       p[i]   = $dat(k=>n-1); 
	       xp[i]  =   $x(k=>n-1) + (dex + 1 - n);
	   } else {
	       p[i] =  $dat(k=>dex);
	       xp[i] =   $x(k=>dex);
	   }
       }
       // do the actual calculation (see, e.g., http://en.wikipedia.org/wiki/Cspline)
//       if(xp[3]==xp[2]) 
//	 xp[3]++;
//       if(xp[0] == xp[1]) 
//	 xp[0]--;
//	 printf("xp: %g %g %g %g; x=%g\n",xp[0],xp[1],xp[2],xp[3],$xloc());
       {
	   double t = ($xloc() - xp[1]) / (xp[2]-xp[1]);
	   double t1 = 1 - t;
	   double h00 = (1 + 2*t) * t1 * t1;
	   double h10 = t * t1 * t1;
	   double h01 = t * t * (3 - 2*t);
	   double h11 = - t * t * t1;
	   double m0 = (1 - $c()) * ( p[2] - p[0] ) / (1 + (xp[1]-xp[0])/(xp[2]-xp[1]));
	   double m1 = (1 - $c()) * ( p[3] - p[1] ) / (1 + (xp[3]-xp[2])/(xp[2]-xp[1]));

	   $out() =  h00 * p[1]  +  h10 * m0  +  h01 * p[2]  +  h11 * m1;
       }
       } // end of else

EOC
       );
EOF


   
print "Loaded CubeMarkup\n";

1;
