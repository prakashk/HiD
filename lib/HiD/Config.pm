package HiD::Config;
# ABSTRACT: Configuration info for HiD
use Mouse;
use namespace::autoclean;

use Class::Load        qw/ :all /;
use File::Basename;
use File::Find::Rule;
use HiD::Layout;
use HiD::Page;
use HiD::Post;
use HiD::RegularFile;
use HiD::Types;
use Try::Tiny;
use YAML::XS           qw/ LoadFile /;

=attr config

=cut

has config => (
  is      => 'ro' ,
  isa     => 'HashRef' ,
  lazy    => 1 ,
  builder => '_build_config' ,
);

sub _build_config {
  my $file = shift->config_file;
  # FIXME error handling?
  return -e -f -r $file ? LoadFile $file : {};
}

=attr config_file

=cut

has config_file => (
  is      => 'ro' ,
  isa     => 'Str' ,
  default => '_config.yml' ,
);

=attr files

=cut

has files => (
  is      => 'ro' ,
  isa     => 'HashRef',
  default => sub {{}} ,
  traits  => ['Hash'],
  handles => {
    add_file      => 'set' ,
    seen_file     => 'exists' ,
    get_file_type => 'get' ,
    all_files     => 'keys' ,
  },
);

=attr include_dir

=cut

has include_dir => (
  is      => 'ro' ,
  isa     => 'Maybe[HiD_DirPath]' ,
  lazy    => 1,
  default => sub {
    my $self = shift;
    $self->config->{include_dir} //
      ( -e -d '_includes' ) ? '_includes' : undef;
  } ,
);

=attr layout_dir

=cut

has layout_dir => (
  is      => 'ro' ,
  isa     => 'HiD_DirPath' ,
  lazy    => 1 ,
  default => '_layouts' ,
);

=attr layouts

=cut

has layouts => (
  is      => 'ro' ,
  isa     => 'HashRef[HiD::Layout]',
  lazy    => 1 ,
  builder => '_build_layouts',
  traits  => ['Hash'] ,
  handles => {
    get_layout_by_name => 'get' ,
  },
);

sub _build_layouts {
  my $self = shift;

  my @layout_files = File::Find::Rule->file
    ->in( $self->layout_dir );

  my %layouts;
  foreach my $layout_file ( @layout_files ) {
    my $dir = $self->layout_dir;

    my( $layout_name , $extension ) = $layout_file
      =~ m|^$dir/(.*)\.([^.]+)$|;

    $layouts{$layout_name} = HiD::Layout->new({
      filename => $layout_file
    });

    $self->add_file( $layout_file => 'layout' );
  }

  foreach my $layout_name ( keys %layouts ) {
    my $metadata = $layouts{$layout_name}->metadata;

    if ( my $embedded_layout = $metadata->{layout} ) {
      die "FIXME embedded layout fail $embedded_layout"
        unless $layouts{$embedded_layout};

      $layouts{$layout_name}->set_layout(
        $layouts{$embedded_layout}
      );
    }
  }

  return \%layouts;
}

=attr objects

=cut

has objects => (
  is  => 'ro' ,
  isa => 'ArrayRef[Object]' ,
  traits => [ 'Array' ] ,
  default => sub{[]} ,
  handles => {
    add_object  => 'push' ,
    all_objects => 'elements' ,
  },
);

=attr page_file_regex

=cut

has page_file_regex => (
  is      => 'ro' ,
  isa     => 'RegexpRef',
  default => sub { qr/\.(mk|mkd|mkdn|markdown|textile|html)$/ } ,
);

=attr pages

=cut

has pages => (
  is      => 'ro',
  isa     => 'Maybe[ArrayRef[HiD::Page]]',
  lazy    => 1 ,
  builder => '_build_pages' ,
);

sub _build_pages {
  my $self = shift;

  # build posts before pages
  $self->posts;

  my @potential_pages = File::Find::Rule->file->
    name( $self->page_file_regex )->in( '.' );

  my @pages = grep { $_ } map {
    if ($self->seen_file( $_ ) or $_ =~ /^_/ ) { 0 }
    else {
      try {
        my $page = HiD::Page->new( filename => $_ , hid => $self );
        $page->content;
        $self->add_file( $_ => 'page' );
        $self->add_object( $page );
        $page;
      }
      catch { 0 };
    }
  } @potential_pages;

  return \@pages;
}

=attr post_file_regex

=cut

has post_file_regex => (
  is      => 'ro' ,
  isa     => 'RegexpRef' ,
  default => sub { qr/^[0-9]{4}-[0-9]{2}-[0-9]{2}-(?:.+?)\.(?:mk|mkd|mkdn|markdown)$/ },
);

=attr posts_dir

=cut

has posts_dir => (
  is      => 'ro' ,
  isa     => 'HiD_DirPath' ,
  lazy    => 1 ,
  default => '_posts' ,
);

=attr posts

=cut

has posts => (
  is      => 'ro' ,
  isa     => 'Maybe[ArrayRef[HiD::Post]]' ,
  lazy    => 1 ,
  builder => '_build_posts' ,
);

sub _build_posts {
  my $self = shift;

  # build layouts before posts
  $self->layouts;

  my @potential_posts = File::Find::Rule->file
    ->name( $self->post_file_regex )->in( $self->posts_dir );

  my @posts = grep { $_ } map {
    try {
      my $post = HiD::Post->new( filename => $_ , hid => $self );
      $self->add_file( $_ => 'post' );
      $self->add_object( $post );
      $post
    };
  } @potential_posts;

  return \@posts;
}

=attr processor

=cut

has processor => (
  is      => 'ro' ,
  isa     => 'HiD::Processor' ,
  lazy    => 1 ,
  handles => [ qw/ process / ] ,
  builder => '_build_processor' ,
);

sub _build_processor {
  my $self = shift;

  my $processor_name  = $self->config->{processor_name} // 'Template';

  my $processor_class = ( $processor_name =~ /^\+/ ) ? $processor_name
    : "HiD::Processor::$processor_name";

  try_load_class( $processor_class );

  return $processor_class->new( $self->processor_args );
}

has processor_args => (
  is      => 'ro' ,
  isa     => 'ArrayRef|HashRef' ,
  lazy    => 1 ,
  default => sub {
    my $self = shift;

    return $self->config->{processor_args} if
      defined $self->config->{processor_args};

    my $include_path = $self->layout_dir;
    $include_path   .= ':' . $self->include_dir
      if defined $self->include_dir;

    return {
      INCLUDE_PATH => $include_path ,
      DEFAULT      => $self->get_layout_by_name( 'default' )->filename ,
    };
  },
);

=attr regular_files

=cut

has regular_files => (
  is      => 'ro',
  isa     => 'Maybe[ArrayRef[HiD::RegularFile]]',
  lazy    => 1 ,
  builder => '_build_regular_files' ,
);

sub _build_regular_files {
  my $self = shift;

  # build pages before regular files
  $self->pages;

  my @potential_files = File::Find::Rule->file->in( '.' );

  my @files = grep { $_ } map {
    if ($self->seen_file( $_ ) or $_ =~ /^_/ ) { 0 }
    else {
      my $file = HiD::RegularFile->new({ filename => $_ , hid => $self });
      $self->add_file( $_ => 'file' );
      $self->add_object( $file );
      $file;
    }
  } @potential_files;

  return \@files;
}

=attr site_dir

=cut

has site_dir => (
  is      => 'ro' ,
  isa     => 'HiD_DirPath' ,
  lazy    => 1 ,
  builder => '_build_site_dir' ,
);

sub _build_site_dir { return shift->config->{site_dir} // '_site' }

__PACKAGE__->meta->make_immutable;
1;