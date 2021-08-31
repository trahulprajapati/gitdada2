my $collb = [
          {
            'project' => 18
          },
          {
            'project' => 19
          },
          {
            'project' => 91
          },
          {
            'project' => 92
          },
          {
            'project' => 75
          }
        ];
my @vals;
map {push @vals, $_->{'project'} } @$collb;
use Data::Dumper; print Dumper \@vals;
my $placeholders = join ", ", ("?") x @vals;
die "-- $placeholders \n";