package Gitprep::Manager;

use strict;
use warnings;

use Mojo::Base -base;

use Carp 'croak';
use Encode 'encode';
use File::Copy qw/move copy/;
use File::Path qw/mkpath rmtree/;
use File::Temp ();
use File::Spec::Functions;
use Fcntl ':flock';
use Carp 'croak';
use File::Copy qw/copy move/;
use File::Spec;
use Gitprep::Util;
use File::Size;
use Number::Bytes::Human qw(format_bytes parse_bytes);

use Mojo::JWT;

use Email::Sender::Simple qw(sendmail);
use Email::Sender::Transport::SMTP ();
use Email::Sender::Transport::SMTP::TLS;
use Email::Simple ();
use Email::Simple::Creator ();

has 'app';
has 'authorized_keys_file';

has '_tmp_branch' => '__gitprep_tmp_branch__';

sub prepare_merge {
  my ($self, $work_rep_info, $base_rep_info, $base_branch, $target_rep_info, $target_branch) = @_;
  
  # Fetch base repository
  my $base_user_id = $base_rep_info->{user};
  my @git_fetch_base_cmd = $self->app->git->cmd($work_rep_info, 'fetch', 'origin');
  Gitprep::Util::run_command(@git_fetch_base_cmd)
    or Carp::croak "Can't execute git fetch: @git_fetch_base_cmd";
  
  # Fetch target repository
  my @git_fetch_target_cmd = $self->app->git->cmd($work_rep_info, 'fetch', $target_rep_info->{git_dir});
  
  Gitprep::Util::run_command(@git_fetch_target_cmd)
    or Carp::croak "Can't execute git fetch: @git_fetch_target_cmd";

  # Ensure no diff
  my @git_reset_hard_cmd = $self->app->git->cmd(
    $work_rep_info,
    'reset',
    '--hard'
  );
  Gitprep::Util::run_command(@git_reset_hard_cmd)
    or Carp::croak "Can't execute git reset --hard: @git_reset_hard_cmd";

  # Checkout first branch
  my $tmp_branch = $self->_tmp_branch;
  my $branch_names = $self->app->git->branch_names($work_rep_info);
  my $first_branch;
  for my $branch_name (@$branch_names) {
    if ($branch_name ne $tmp_branch) {
      $first_branch = $branch_name;
      last;
    }
  }
  my @git_checkout_first_branch = $self->app->git->cmd(
    $work_rep_info,
    'checkout',
    $first_branch
  );
  Gitprep::Util::run_command(@git_checkout_first_branch)
    or Carp::croak "Can't execute git checkout: @git_checkout_first_branch";
  
  # Delete temparary branch if it eixsts
  if (grep { $_ eq $tmp_branch } @$branch_names) {
    my @git_branch_remove_cmd = $self->app->git->cmd(
      $work_rep_info,
      'branch',
      '-D',
      $tmp_branch
    );
    Gitprep::Util::run_command(@git_branch_remove_cmd)
      or Carp::croak "Can't execute git branch: @git_branch_remove_cmd";
  }

  # Create temparary branch
  my @git_branch_cmd = $self->app->git->cmd(
    $work_rep_info,
    'branch',
    $tmp_branch
  );
  Gitprep::Util::run_command(@git_branch_cmd)
    or Carp::croak "Can't execute git branch: @git_branch_cmd";
  
  # Checkout tmp branch and git reset --hard from my remote branch
  my @git_checkout_tmp_branch = $self->app->git->cmd(
    $work_rep_info,
    'checkout',
    $tmp_branch
  );
  Gitprep::Util::run_command(@git_checkout_tmp_branch)
    or Carp::croak "Can't execute git checkout: @git_checkout_tmp_branch";
  
  # git reset --hard 
  my $base_object_id = $self->app->git->ref_to_object_id($base_rep_info, $base_branch);
  my @git_reset_hard_base_cmd = $self->app->git->cmd(
    $work_rep_info,
    'reset',
    '--hard',
    $base_object_id
  );
  Gitprep::Util::run_command(@git_reset_hard_base_cmd)
    or Carp::croak "Can't execute git reset --hard: @git_reset_hard_base_cmd";
}

sub convert_size {
  my $info = {}, my $size_letter, my $preSize, my $t=0;
  my ($self, $getsize, @ssize) = @_;
  do{
      $preSize = $getsize;
      $size_letter = "$ssize[$t]";
      $getsize /= 1000;
      $t += 1;
  }while($getsize >= 1);
  $info->{size} = sprintf("%.3f", $preSize);
  $info->{unit} = $size_letter;
  return $info;
}

sub merge {
  my ($self, $work_rep_info, $target_rep_info, $target_branch, $pull_request_number) = @_;
  
  my $object_id = $self->app->git->ref_to_object_id($target_rep_info, $target_branch);
  
  my $message;
  my $target_user_id = $target_rep_info->{user};
  if (defined $pull_request_number) {
    $message = "Merge pull request #$pull_request_number from $target_user_id/$target_branch";
  }
  else {
    $message = "Merge from $target_user_id/$target_branch";
  }
  
  # Merge
  my @git_merge_cmd = $self->app->git->cmd(
    $work_rep_info,
    'merge',
    '--no-ff',
    "--message=$message",
    $object_id
  );
  # 
  
  my $success = Gitprep::Util::run_command(@git_merge_cmd);
  
  return $success;
}

sub get_patch {
  my ($self, $work_rep_info, $target_rep_info, $target_branch) = @_;
  
  my $object_id = $self->app->git->ref_to_object_id($target_rep_info, $target_branch);
  
  # Merge
  my @git_format_patch_cmd = $self->app->git->cmd(
    $work_rep_info,
    'format-patch',
    '--stdout',
    "HEAD..$object_id"
  );
  
  open my $fh, '-|', @git_format_patch_cmd
    or croak "Execute git format-patch cmd:@git_format_patch_cmd";
  
  my $patch = do { local $/; <$fh> };
  
  return $patch;
}

sub push {
  my ($self, $work_rep_info, $base_branch) = @_;
  
  # Push
  my $tmp_branch = $self->_tmp_branch;
  my @git_push_cmd = $self->app->git->cmd(
    $work_rep_info,
    'push',
    'origin',
    "$tmp_branch:$base_branch"
  );
  Gitprep::Util::run_command(@git_push_cmd)
    or Carp::croak "Can't execute git push: @git_push_cmd";
}

sub lock_rep {
  my ($self, $rep_info) = @_;
  
  my $git_dir = $rep_info->{git_dir};
  my $lock_file = "$git_dir/config";
  
  open my $lock_fh, '<', $lock_file
    or croak "Can't open lock file $lock_file: $!";
    
  flock $lock_fh, LOCK_EX
    or croak "Can't lock $lock_file";
  
  return $lock_fh;
}

sub create_work_rep {
  my ($self, $user, $project) = @_;
  
  # Remote repository
  my $rep_info = $self->app->rep_info($user, $project);
  my $rep_git_dir = $rep_info->{git_dir};
  
  # Working repository
  my $work_rep_info = $self->app->work_rep_info($user, $project);
  my $work_tree = $work_rep_info->{work_tree};
  
  # Create working repository if it don't exist
  unless (-e $work_tree) {

    # git clone
    my @git_clone_cmd = ($self->app->git->bin, 'clone', $rep_git_dir, $work_tree);
    Gitprep::Util::run_command(@git_clone_cmd)
      or croak "Can't git clone: @git_clone_cmd";
    
    # Set user name
    my @git_config_user_name = $self->app->git->cmd(
      $work_rep_info,
      'config',
      'user.name',
      $user
    );
    Gitprep::Util::run_command(@git_config_user_name)
      or croak "Can't execute git config: @git_config_user_name";
    
    # Set user email
    my $user_email = $self->app->dbi->model('user')->select('email', where => {id => $user})->value;
    my @git_config_user_email = $self->app->git->cmd(
      $work_rep_info,
      'config',
      'user.email',
      "$user_email"
    );
    Gitprep::Util::run_command(@git_config_user_email)
      or croak "Can't execute git config: @git_config_user_email";
  }
}

sub admin_user {
  my $self = shift;
  
  # Admin user
  my $admin_user = $self->app->dbi->model('user')
    ->select(where => {admin => 1})->one;
  
  return $admin_user;
}

sub default_branch {
  my ($self, $user_id, $project_id, $default_branch) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # Set default branch
  my $dbi = $self->app->dbi;
  if (defined $default_branch) {
    $dbi->model('project')->update(
      {default_branch => $default_branch},
      where => {user => $user_row_id, id => $project_id}
    );
  }
  else {
    # Get default branch
    my $default_branch = $dbi->model('project')
      ->select('default_branch', where => {user => $user_row_id, id => $project_id})
      ->value;
    
    return $default_branch;
  }
}

sub fork_project {
  my ($self, $forked_user_id, $user_id, $project_id) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # Fork project
  my $dbi = $self->app->dbi;
  my $error;
  eval {
    $dbi->connector->txn(sub {
      
      # Original project id
      my $project = $dbi->model('project')->select(
        {__MY__ => ['row_id', 'private']},
        where => {'user.id' => $user_id, 'project.id' => $project_id}
      )->one;
      
      # Create project
      eval {
        $self->_create_project(
          $forked_user_id,
          $project_id,
          {
            original_project => $project->{row_id},
            private => $project->{private}
          }
        );
      };
      croak $error = $@ if $@;
      
      # Create repository
      eval {
        $self->_fork_rep($user_id, $project_id, $forked_user_id, $project_id);
      };
      croak $error = $@ if $@;
    });
  };
  croak $error if $@;
}

sub is_admin {
  my ($self, $user_id) = @_;
  
  # Check admin
  my $is_admin = $self->app->dbi->model('user')
    ->select('admin', where => {id => $user_id})->value;
  
  return $is_admin;
}

sub is_private_project {
  my ($self, $user_id, $project_id) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # Is private
  my $private = $self->app->dbi->model('project')->select(
    'private', where => {user => $user_row_id, id => $project_id}
  )->value;
  
  return $private;
}

sub api { shift->app->gitprep_api }


sub member_projects {
  my ($self, $user_id, $project_id) = @_;
  
  # DBI
  my $dbi = $self->app->dbi;
  
  # project id
  my $project_row_id = $dbi->model('project')->select(
    'project.row_id',
    where => {'user.id' => $user_id, 'project.id' => $project_id}
  )->value;
  
  # Members
  my $member_projects = $dbi->model('project')->select(
    [
      {__MY__ => ['id']},
      {user => ['id']}
    ],
    where => {
      original_project => $project_row_id,
    },
    append => 'order by "user".id, project.id'
  )->all;

  return $member_projects;
}

sub create_project {
  my ($self, $user_id, $project_id, $opts) = @_;
  
  my $params = {};
  if ($opts->{private}) {
    $params->{private} = 1;
  }
  
  if ($opts->{'proj_type'}) {
    $params->{'proj_type'} = 1; 
  }
  # Create project
  my $dbi = $self->app->dbi;
  my $error;
  eval {
    $dbi->connector->txn(sub {
      eval { $self->_create_project($user_id, $project_id, $params) };
      croak $error = $@ if $@;
      eval {$self->_create_rep($user_id, $project_id, $opts) };
      croak $error = $@ if $@;
    });
  };
  croak $error if $@;
}

sub create_user {
  my ($self, $user, $data) = @_;

  # Create user
  my $dbi = $self->app->dbi;
  my $error;
  eval {
    $dbi->connector->txn(sub {
      eval { $self->_create_db_user($user, $data) };
      croak $error = $@ if $@;
      eval {$self->_create_user_dir($user) };
      croak $error = $@ if $@;
    });
  };
  croak $error if $@;
}

sub delete_project {
  my ($self, $user, $project) = @_;
  
  # Delete project
  my $dbi = $self->app->dbi;
  my $error;
  eval {
    $dbi->connector->txn(sub {
      eval { $self->_delete_project($user, $project) };
      croak $error = $@ if $@;
      eval {$self->_delete_rep($user, $project) };
      croak $error = $@ if $@;
    });
  };
  croak $error if $@;
}

sub delete_user {
  my ($self, $user) = @_;
  
  # Delete user
  my $dbi = $self->app->dbi;
  my $error;
  my $count;
  eval {
    $dbi->connector->txn(sub {
      eval { $count = $self->_delete_db_user($user) };
      croak $error = $@ if $@;
      eval {$self->_delete_user_dir($user) };
      croak $error = $@ if $@;
    });
  };
  croak $error if $@;
  
  return $count;
}

sub original_project {
  my ($self, $user_id, $project_id) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # Original project id
  my $dbi = $self->app->dbi;
  my $original_project_row_id = $dbi->model('project')->select(
    'original_project',
    where => {user => $user_row_id, id => $project_id}
  )->value;
  
  croak "Original project don't eixsts." unless defined $original_project_row_id;
  
  # Original project
  my $original_project = $dbi->model('project')->select(
    [
      '"project"."row_id" as "row_id"', 
      '"project"."user" as "user"',
      '"project"."id" as "id"', 
      '"project"."default_branch" as "default_branch"',
      '"project"."original_project" as "original_project"',
      '"project"."private" as "private"',
      '"project"."ignore_space_change" as "ignore_space_change"',
      '"project"."guess_encoding" as "guess_encoding"',
      '"project"."website_url" as "website_url"', 
      '"project"."proj_type" as "proj_type"',
      '"user"."id" as "user_id"'
    ],
    where => {
      'project.row_id' => $original_project_row_id
    }
  )->one;
  # my $original_project = $dbi->model('project')->select(
  #   [
  #     {__MY__ => '*'},
  #     {user => ['id']}
  #   ],
  #   where => {
  #     'project.row_id' => $original_project_row_id
  #   }
  # )->one;
  return unless defined $original_project;
  
  return $original_project;
}

sub child_project {
  my ($self, $user_id, $project_id, $child_user_id) = @_;
  
  my $project_row_id = $self->app->dbi->model('project')->select(
    'project.row_id', where => {'user.id' => $user_id, 'project.id' => $project_id}
  )->value;
  
  my $child_project = $self->app->dbi->model('project')->select(
    [
     '"project"."row_id" as "row_id"', 
      '"project"."user" as "user"',
      '"project"."id" as "id"', 
      '"project"."default_branch" as "default_branch"',
      '"project"."original_project" as "original_project"',
      '"project"."private" as "private"',
      '"project"."ignore_space_change" as "ignore_space_change"',
      '"project"."guess_encoding" as "guess_encoding"',
      '"project"."website_url" as "website_url"', 
      '"project"."proj_type" as "proj_type"',
      '"user"."id" as "user_id"'
    ],
    where => {
      'project.original_project' => $project_row_id,
      'user.id' => $child_user_id
    }
  )->one;
  # my $child_project = $self->app->dbi->model('project')->select(
  #   [
  #     {__MY__ => '*'},
  #     {user => ['id']}
  #   ],
  #   where => {
  #     'project.original_project' => $project_row_id,
  #     'user.id' => $child_user_id
  #   }
  # )->one;
  
  return $child_project;
}

sub projects {
  my ($self, $user_id) = @_;
  
  my $user_row_id = $self->app->dbi->model('user')->select('row_id', where => {id => $user_id})->value;
  # Projects
  my $projects = $self->app->dbi->model('project')->select(
    where => {user => $user_row_id},
    append => 'order by id'
  )->all;
  
  return $projects;
}

sub collb_projects {
  my ($self, $user_id) = @_;
  #collaborator projects
  my $user_row_id = $self->app->dbi->model('user')->select('row_id', where => {id => $user_id})->value;
  my $collb = $self->app->dbi->model('collaboration')->select('project', where => {user => $user_row_id})->all;
  my @vals;
  map {push @vals, $_->{'project'}} @$collb;

  my $collab_projects = $self->app->dbi->model('project')->select(
    [
      '"project"."row_id" as "row_id"', 
      '"project"."user" as "user"',
      '"project"."id" as "id"', 
      '"project"."default_branch" as "default_branch"',
      '"project"."original_project" as "original_project"',
      '"project"."private" as "private"',
      '"project"."ignore_space_change" as "ignore_space_change"',
      '"project"."guess_encoding" as "guess_encoding"',
      '"project"."website_url" as "website_url"', 
      '"project"."proj_type" as "proj_type"',
      '"user"."id" as "user_id"'
    ],
    where => {'project.row_id' => \@vals},
  )->all;
  # Projects
  # my $collab_projects = $self->app->dbi->model('project')->select(
  #   where => {row_id => \@vals},
  #   append => 'order by id'
  # )->all;

  return $collab_projects;
}

sub users {
  my $self = shift;
  
  # Users
  my $users = $self->app->dbi->model('user')->select(
    where => [':admin{<>}',{admin => 1}],
    append => 'order by id'
  )->all;
  
  return $users;
}

sub rename_project {
  my ($self, $user, $project, $to_project) = @_;
  
  # Rename project
  my $git = $self->app->git;
  my $dbi = $self->app->dbi;
  my $error;
  eval {
    $dbi->connector->txn(sub {
      eval { $self->_rename_project($user, $project, $to_project) };
      croak $error = $@ if $@;
      eval { $self->_rename_rep($user, $project, $to_project) };
      croak $error = $@ if $@;
    });
  };
  croak $error if $error;
}

sub update_authorized_keys_file {
  my $self = shift;

  my $authorized_keys_file = $self->authorized_keys_file;
  if (defined $authorized_keys_file) {
    
    # Lock file
    my $lock_file = $self->app->home->rel_file('lock/authorized_keys');
    open my $lock_fh, $lock_file
      or croak "Can't open lock file $lock_file";
    flock $lock_fh, LOCK_EX
      or croak "Can't lock $lock_file";
    
    # Create authorized_keys_file
    unless (-f $authorized_keys_file) {
      open my $fh, '>', $authorized_keys_file
        or croak "Can't create authorized_keys file: $authorized_keys_file";
      chmod 0600, $authorized_keys_file
        or croak "Can't chmod authorized_keys file: $authorized_keys_file";
    }
    
    # Parse file
    my $result = $self->parse_authorized_keys_file($authorized_keys_file);
    my $before_part = $result->{before_part};
    my $gitprep_part = $result->{gitprep_part};
    my $after_part = $result->{after_part};
    my $start_symbol = $result->{start_symbol};
    my $end_symbol = $result->{end_symbol};
    
    # Backup at first time
    if ($gitprep_part eq '') {
      # Backup original file
      my $to = "$authorized_keys_file.gitprep.original";
      unless (-f $to) {
        copy $authorized_keys_file, $to
          or croak "Can't copy $authorized_keys_file to $to";
      }
    }

    # Create public keys
    my $ssh_public_keys = $self->app->dbi->model('ssh_public_key')->select(
      [
        {__MY__ => '*'},
        {user => ['id']}
      ]
    )->all;
    my $ssh_public_keys_str = '';
    for my $key (@$ssh_public_keys) {
      my $ssh_public_key_str = 'command="' . $self->app->home->rel_file('script/gitprep-shell')
        . " $key->{'user.id'}\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $key->{key}";
      $ssh_public_keys_str .= "$ssh_public_key_str $key->{'user.id'}\n\n";
    }
    
    # Output tmp file
    my $output = "$before_part$start_symbol\n\n$ssh_public_keys_str$end_symbol$after_part";
    my $output_file = "$authorized_keys_file.gitprep.tmp";
    open my $out_fh, '>', $output_file
      or croak "Can't create authorized_keys tmp file $output_file";
    print $out_fh $output;
    close $out_fh
      or croak "Can't close authorized_keys tmp file $output_file";

    # Replace
    chmod 0600, $output_file
      or croak "Can't chmod authorized_keys tmp file: $output_file";
    move $output_file, $authorized_keys_file
      or croak "Can't replace $authorized_keys_file by $output_file";
  }
  else {
    croak qq/authorized_keys file "$authorized_keys_file" is not found./;
  }
}

sub parse_authorized_keys_file {
  my ($self, $file) = @_;
  
  my $start_symbol = "# gitprep start";
  my $end_symbol = "# gitprep end";
  
  # Parse
  open my $fh, '<', $file
    or croak "Can't open authorized_key file $file";
  my $start_symbol_count = 0;
  my $end_symbol_count = 0;
  my $before_part = '';
  my $gitprep_part = '';
  my $after_part = '';
  my $error_prefix = "authorized_keys file $file format error:";
  while (my $line = <$fh>) {
    if ($line =~ /^$start_symbol/) {
      if ($start_symbol_count > 0) {
        croak qq/$error_prefix "$start_symbol" is found more than one/;
      }
      else {
        if ($end_symbol_count > 0) {
          croak qq/$error_prefix "$end_symbol" is found before "$start_symbol"/;
        }
        else {
          $start_symbol_count++;
        }
      }
    }
    elsif ($line =~ /^$end_symbol/) {
      if ($end_symbol_count > 0) {
        croak qq/$error_prefix "$end_symbol" is found more than one/;
      }
      else {
        $end_symbol_count++;
      }
    }
    elsif ($start_symbol_count == 0 && $end_symbol_count == 0) {
      $before_part .= $line;
    }
    elsif ($start_symbol_count == 1 && $end_symbol_count == 0) {
      $gitprep_part .= $line;
    }
    elsif ($start_symbol_count == 1 && $end_symbol_count == 1) {
      $after_part .= $line;
    }
  }
  
  my $result = {
    start_symbol => $start_symbol,
    end_symbol => $end_symbol,
    before_part => $before_part,
    gitprep_part => $gitprep_part,
    after_part => $after_part
  };
  
  return $result;
}

sub _create_project {
  my ($self, $user_id, $project_id, $params) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  $params ||= {};
  $params->{user} = $user_row_id;
  $params->{id} = $project_id;
  
  # Create project
  my $dbi = $self->app->dbi;
  $dbi->connector->txn(sub {
    $dbi->model('project')->insert($params);
  });
}

sub _create_rep {
  my ($self, $user, $project, $opts) = @_;
  
  # Create repository directory
  my $git = $self->app->git;
  
  my $rep_info = $self->app->rep_info($user, $project);
  my $rep_git_dir = $rep_info->{git_dir};
  mkdir $rep_git_dir
    or croak "Can't create directory $rep_git_dir: $!";
  
  eval {
    # Git init
    {
      my @git_init_cmd = $git->cmd($rep_info, 'init', '--bare');
      Gitprep::Util::run_command(@git_init_cmd)
        or croak  "Can't execute git init --bare:@git_init_cmd";
    }
    
    # Add git-daemon-export-ok
    {
      my $file = "$rep_git_dir/git-daemon-export-ok";
      open my $fh, '>', $file
        or croak "Can't create git-daemon-export-ok: $!"
    }
    
    # HTTP support
    my @git_update_server_info_cmd = $git->cmd(
      $rep_info,
      '--bare',
      'update-server-info'
    );
    Gitprep::Util::run_command(@git_update_server_info_cmd)
      or croak "Can't execute git --bare update-server-info";
    move("$rep_git_dir/hooks/post-update.sample", "$rep_git_dir/hooks/post-update")
      or croak "Can't move post-update";
    
    # Description
    my $description = $opts->{description};
    $description = '' unless defined $description;
    {
      my $file = "$rep_git_dir/description";
      open my $fh, '>', $file
        or croak "Can't open $file: $!";
      print $fh encode('UTF-8', $description)
        or croak "Can't write $file: $!";
      close $fh;
    }
    
    # add post-recieve hook if its web projects
    if ($opts->{'proj_type'}) {
      #create a post-recieve hooks
      # Create working directory
      my $home_tmp_dir = $self->app->home->rel_file('tmp');
      
      #checkout the branch
      my $udir = catdir($home_tmp_dir, $user);
      if (!-d $udir) {
        mkdir $udir or croak("Unable to create tmp dir $udir - $!");
      }
      my $tmp_rep_dir = catdir($udir, $project);
      if (-d $tmp_rep_dir) {
        rmtree ($tmp_rep_dir) or croak("Unable to delete dir $tmp_rep_dir - $!");
      }
      mkdir $tmp_rep_dir or croak("Unable to create tmp dir $udir - $!");

      #--git-dir = $rep_git_dir , --work-tree = $tmp_rep_dir
      #create post-recieve hooks

      #content
      my $tproj_dir = "/home/pronoor/gitdada/$project";
      my $usr = "pronoor";
      my $paswd = "pronoor231";
      my $trg_host = "148.59.34.110";

      my $content = <<"HERE";
#!/bin/bash
proj=$project
tproj_dir=$tproj_dir
usr=$usr
paswd=$paswd
trg_host=$trg_host
tmp_rep_dir=$tmp_rep_dir
rep_git_dir=$rep_git_dir

while read oldrev newrev ref
do
    if [[ \$ref =~ .*/master\$ ]];
    then
        echo "Master ref received.  Deploying master branch to production..."

        if [ ! -d "\$tmp_rep_dir" ]; then
          mkdir -p $tmp_rep_dir
        fi
        git --work-tree=\$tmp_rep_dir --git-dir=\$rep_git_dir checkout -f
        status=\$?
        if [ \$status -eq 1 ]; then
      echo "Something went wrong. Exiting...";
      exit 1
    fi
    
    #mkdir proj on taret
    #ssh \$usr\@\$trg_host "mkdir -p $tproj_dir"
    #stt0=\$?
    #if [ \$stt0 -eq 1 ]; then
    #    echo "Unable to create project dir - $tproj_dir. Exiting.."
    #    exit
    #fi
    #Coping repo to target
    echo "Coping repo to target"
    scp -r \$tmp_rep_dir \$usr\@\$trg_host:\$tproj_dir
    st0=\$?
    if [ \$st0 -eq 1 ]; then
        echo "Error whie coping repo to target. Exiting.."
        exit
    fi

    #moving repo to /var/www/html
    echo "moving repo to /var/www/html"
    ssh \$usr\@\$trg_host "echo \$paswd | sudo -S cp -r \$tproj_dir /var/www/html"
    st01=\$?
    if [ \$st01 -eq 1 ]; then
      ssh \$usr\@\$trg_host "rm -rf \$tproj_dir"
        echo "Error while copy repo to public dir. Exiting.."
        exit 1
    fi


    #Restarting server
    echo "Restarting server"
    ssh \$usr\@\$trg_host "echo \$paswd| sudo -S sudo service apache2 restart"
    st5=\$?
    if [ \$st5 -eq 1 ]; then
      echo "Unable to restart server. Exiting..."
      exit 1
    fi

    #mkdir proj on taret
    ssh \$usr\@\$trg_host "rm -rf $tproj_dir"
    echo "Deployed Successfully"
  else
    echo "Ref \$ref successfully received.  Doing nothing: only the master branch may be deployed on this server."
  fi
done
HERE
      my $post_recieve_file = catfile($rep_git_dir, "hooks", "post-receive");
      open (my $FL, ">", $post_recieve_file) or croak ("Unable to open file $post_recieve_file - $!");
      print $FL $content;
      close $FL;

      if (-z $post_recieve_file) {
        croak ("Unable to create post-receive hooks");
      }
      
      #change the permission
      `chmod +x $post_recieve_file`;
      my $status = $?;
      if ($status >> 8 != 0) {
        croak("Change permission failed. $!");
      }
      #Create index.html page
      # Temp directory
      my $temp_dir =  File::Temp->newdir(DIR => $home_tmp_dir);
      
      # Working repository
      my $work_rep_work_tree = "$temp_dir/work";
      my $work_rep_git_dir = "$work_rep_work_tree/.git";
      my $work_rep_info = {
        work_tree => $work_rep_work_tree,
        git_dir => $work_rep_git_dir
      };
      
      mkdir $work_rep_work_tree
        or croak "Can't create directory $work_rep_work_tree: $!";
      
      # Git init
      my @git_init_cmd = $git->cmd($work_rep_info, 'init', '-q');
      Gitprep::Util::run_command(@git_init_cmd)
        or croak "Can't execute git init: @git_init_cmd";
      
      # Add README
      my $index_html = <<"INDEX";
<html>
  <title> $project </title>
  <h2> Your site is up! Enjoy the new experience</h2>
  <p> You can access your site </p>  <a href="http://pro1.gitdada.com/$project">here</a>
  <br><br><br><br><br><br><br><br><br><br><br><br>
  <br><br><br><br><br><br><br><br><br><br><br><br>
  <br><br><br>
  <footer>
    <p>Powered by MedNoor Product</p>
  </footer> 
</html>
INDEX
      my $file = "$work_rep_work_tree/index.html";
      open my $IFL, '>', $file
        or croak "Can't create $file: $!";
      print $IFL $index_html;
      close $index_html;
      
      my @git_add_cmd = $git->cmd(
        $work_rep_info,
        'add',
        'index.html'
      );
      
      Gitprep::Util::run_command(@git_add_cmd)
        or croak "Can't execute git add: @git_add_cmd";
      
      # Set user name
      my @git_config_user_name = $git->cmd(
        $work_rep_info,
        'config',
        'user.name',
        $user
      );
      Gitprep::Util::run_command(@git_config_user_name)
        or croak "Can't execute git config: @git_config_user_name";
      
      # Set user email
      my $user_email = $self->app->dbi->model('user')->select('email', where => {id => $user})->value;
      my @git_config_user_email = $git->cmd(
        $work_rep_info,
        'config',
        'user.email',
        "$user_email"
      );
      Gitprep::Util::run_command(@git_config_user_email)
        or croak "Can't execute git config: @git_config_user_email";
      
      # Commit
      my @git_commit_cmd = $git->cmd(
        $work_rep_info,
        'commit',
        '-q',
        '-m',
        'first commit'
      );
      Gitprep::Util::run_command(@git_commit_cmd)
        or croak "Can't execute git commit: @git_commit_cmd";
      
      # Push
      {
        my @git_push_cmd = $git->cmd(
          $work_rep_info,
          'push',
          '-q',
          $rep_git_dir,
          'master'
        );
        # (This is bad, but --quiet option can't supress in old git)
        Gitprep::Util::run_command(@git_push_cmd)
          or croak "Can't execute git push: @git_push_cmd";
      }

      #remove temp dir
      rmtree ($tmp_rep_dir) or croak ("Unable to remove tmp dir- $!") if (-d $tmp_rep_dir);
    }
    # Add README and commit
    if ($opts->{readme}) {
      # Create working directory
      my $home_tmp_dir = $self->app->home->rel_file('tmp');
      
      # Temp directory
      my $temp_dir =  File::Temp->newdir(DIR => $home_tmp_dir);
      
      # Working repository
      my $work_rep_work_tree = "$temp_dir/work";
      my $work_rep_git_dir = "$work_rep_work_tree/.git";
      my $work_rep_info = {
        work_tree => $work_rep_work_tree,
        git_dir => $work_rep_git_dir
      };
      
      mkdir $work_rep_work_tree
        or croak "Can't create directory $work_rep_work_tree: $!";
      
      # Git init
      my $git_init_rep = catdir($work_rep_info, '.git');
      if (!-d $git_init_rep) {
        my @git_init_cmd = $git->cmd($work_rep_info, 'init', '-q');
        Gitprep::Util::run_command(@git_init_cmd)
          or croak "Can't execute git init: @git_init_cmd";
      }
      # Add README
      my $file = "$work_rep_work_tree/README.md";
      open my $readme_fh, '>', $file
        or croak "Can't create $file: $!";
      print $readme_fh "# $project\n";
      print $readme_fh "\n" . encode('UTF-8', $description) . "\n";
      close $readme_fh;
      
      my @git_add_cmd = $git->cmd(
        $work_rep_info,
        'add',
        'README.md'
      );
      
      Gitprep::Util::run_command(@git_add_cmd)
        or croak "Can't execute git add: @git_add_cmd";
      
      # Set user name
      my @git_config_user_name = $git->cmd(
        $work_rep_info,
        'config',
        'user.name',
        $user
      );
      Gitprep::Util::run_command(@git_config_user_name)
        or croak "Can't execute git config: @git_config_user_name";
      
      # Set user email
      my $user_email = $self->app->dbi->model('user')->select('email', where => {id => $user})->value;
      my @git_config_user_email = $git->cmd(
        $work_rep_info,
        'config',
        'user.email',
        "$user_email"
      );
      Gitprep::Util::run_command(@git_config_user_email)
        or croak "Can't execute git config: @git_config_user_email";
      
      # Commit
      my @git_commit_cmd = $git->cmd(
        $work_rep_info,
        'commit',
        '-q',
        '-m',
        'first commit'
      );
      Gitprep::Util::run_command(@git_commit_cmd)
        or croak "Can't execute git commit: @git_commit_cmd";
      
      # Push
      {
        my @git_push_cmd = $git->cmd(
          $work_rep_info,
          'push',
          '-q',
          $rep_git_dir,
          'master'
        );
        # (This is bad, but --quiet option can't supress in old git)
        Gitprep::Util::run_command(@git_push_cmd)
          or croak "Can't execute git push: @git_push_cmd";
      }
    }
  };
  if (my $e = $@) {
    rmtree $rep_git_dir;
    croak $e;
  }
}

sub create_wiki_rep {
  my ($self, $user, $project) = @_;
  
  # Create repository directory
  my $git = $self->app->git;
  
  my $wiki_rep_info = $self->app->wiki_rep_info($user, $project);
  my $wiki_rep_git_dir = $wiki_rep_info->{git_dir};
  
  mkdir $wiki_rep_git_dir
    or croak "Can't create directory $wiki_rep_git_dir: $!";
  
  eval {
    # Git init
    {
      my @git_init_cmd = $git->cmd($wiki_rep_info, 'init', '--bare');
      Gitprep::Util::run_command(@git_init_cmd)
        or croak  "Can't execute git init --bare:@git_init_cmd";
    }
    
    # Add git-daemon-export-ok
    {
      my $file = "$wiki_rep_git_dir/git-daemon-export-ok";
      open my $fh, '>', $file
        or croak "Can't create git-daemon-export-ok: $!"
    }
    
    # HTTP support
    my @git_update_server_info_cmd = $git->cmd(
      $wiki_rep_info,
      '--bare',
      'update-server-info'
    );
    Gitprep::Util::run_command(@git_update_server_info_cmd)
      or croak "Can't execute git --bare update-server-info";
    move("$wiki_rep_git_dir/hooks/post-update.sample", "$wiki_rep_git_dir/hooks/post-update")
      or croak "Can't move post-update";
  };
  if (my $e = $@) {
    rmtree $wiki_rep_git_dir;
    croak $e;
  }
}

sub create_wiki_work_rep {
  my ($self, $user, $project) = @_;
  
  # Remote repository
  my $wiki_rep_info = $self->app->wiki_rep_info($user, $project);
  my $wiki_rep_git_dir = $wiki_rep_info->{git_dir};
  
  # Working repository
  my $wiki_work_rep_info = $self->app->wiki_work_rep_info($user, $project);
  my $work_tree = $wiki_work_rep_info->{work_tree};
  
  # Create working repository if it don't exist
  unless (-e $work_tree) {

    # git clone
    my @git_clone_cmd = ($self->app->git->bin, 'clone', $wiki_rep_git_dir, $work_tree);
    Gitprep::Util::run_command(@git_clone_cmd)
      or croak "Can't git clone: @git_clone_cmd";
    
    # Set user name
    my @git_config_user_name = $self->app->git->cmd(
      $wiki_work_rep_info,
      'config',
      'user.name',
      $user
    );
    Gitprep::Util::run_command(@git_config_user_name)
      or croak "Can't execute git config: @git_config_user_name";
    
    # Set user email
    my $user_email = $self->app->dbi->model('user')->select('email', where => {id => $user})->value;
    my @git_config_user_email = $self->app->git->cmd(
      $wiki_work_rep_info,
      'config',
      'user.email',
      "$user_email"
    );
    Gitprep::Util::run_command(@git_config_user_email)
      or croak "Can't execute git config: @git_config_user_email";
  }
}

sub _create_db_user {
  my ($self, $user_id, $data) = @_;
  
  $data->{id} = $user_id;
  
  # Create database user
  $self->app->dbi->model('user')->insert($data);
}

sub _create_user_dir {
  my ($self, $user) = @_;
  
  # Create user directory
  my $rep_home = $self->app->rep_home;
  my $user_dir = "$rep_home/$user";
  mkpath $user_dir;
}

sub _delete_db_user {
  my ($self, $user_id) = @_;
  
  # Delete database user
  my $count = $self->app->dbi->model('user')->delete(where => {id => $user_id});
  
  return $count;
}

sub _delete_user_dir {
  my ($self, $user) = @_;
  
  # Delete user directory
  my $rep_home = $self->app->rep_home;
  my $user_dir = "$rep_home/$user";
  rmtree $user_dir;
}

sub _delete_project {
  my ($self, $user_id, $project_id) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # Delete project
  my $dbi = $self->app->dbi;
  $dbi->model('project')->delete(where => {user => $user_row_id, id => $project_id});
}

sub _delete_rep {
  my ($self, $user, $project) = @_;

  # Delete repository
  my $rep_home = $self->app->rep_home;
  croak "Can't remove repository. repository home is empty"
    if !defined $rep_home || $rep_home eq '';
  my $rep = "$rep_home/$user/$project.git";
  rmtree $rep;
  croak "Can't remove repository. repository is rest"
    if -e $rep;
}

sub exists_project {
  my ($self, $user_id, $project_id) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # Exists project
  my $dbi = $self->app->dbi;
  my $row = $dbi->model('project')->select(where => {user => $user_row_id, id => $project_id})->one;
  
  return $row ? 1 : 0;
}

sub exists_user {
  my ($self, $user_id) = @_;
  
  # Exists project
  my $row = $self->app->dbi->model('user')->select(where => {id => $user_id})->one;
  
  return $row ? 1 : 0;
}

sub _exists_rep {
  my ($self, $user, $project) = @_;
  
  # Exists repository
  my $rep_info = $self->app->rep_info($user, $project);
  my $rep_git_dir = $rep_info->{git_dir};
  
  return -e $rep_git_dir;
}

sub _fork_rep {
  my ($self, $user_id, $project_id, $to_user_id, $to_project_id) = @_;
  
  # Fork repository
  my $git = $self->app->git;
  
  my $rep_info = $self->app->rep_info($user_id, $project_id);
  my $rep_git_dir = $rep_info->{git_dir};
  
  my $to_rep_info = $self->app->rep_info($to_user_id, $to_project_id);
  my $to_rep_git_dir = $to_rep_info->{git_dir};

  my @cmd = (
    $git->bin,
    'clone',
    '-q',
    '--bare',
    $rep_git_dir,
    $to_rep_git_dir
  );
  Gitprep::Util::run_command(@cmd)
    or croak "Can't fork repository(_fork_rep): @cmd";
  
  # Copy description
  copy "$rep_git_dir/description", "$to_rep_git_dir/description"
    or croak "Can't copy description file(_fork_rep)";
}

sub _rename_project {
  my ($self, $user_id, $project_id, $renamed_project_id) = @_;
  
  my $user_row_id = $self->api->get_user_row_id($user_id);
  
  # Check arguments
  croak "Invalid parameters(_rename_project)"
    unless defined $user_id && defined $project_id && defined $renamed_project_id;
  
  # Rename project
  my $dbi = $self->app->dbi;
  $dbi->model('project')->update(
    {id => $renamed_project_id},
    where => {user => $user_row_id, id => $project_id}
  );
}

sub _rename_rep {
  my ($self, $user, $project, $renamed_project) = @_;
  
  # Check arguments
  croak "Invalid user name or project"
    unless defined $user && defined $project && defined $renamed_project;

  # Rename repository
  my $rep_info = $self->app->rep_info($user, $project);
  my $rep_git_dir = $rep_info->{git_dir};
  
  my $renamed_rep_info = $self->app->rep_info($user, $renamed_project);
  my $renamed_rep_git_dir = $renamed_rep_info->{git_dir};

  move($rep_git_dir, $renamed_rep_git_dir)
    or croak "Can't move $rep_git_dir to $renamed_rep_git_dir: $!";
}

sub add_collaborator {
  my ($self, $ruser, $rproject) = @_;
  my $dbi = $self->app->dbi;

  eval {
      $dbi->model('collaboration')->insert(
      {
        project => $rproject,
        user => $ruser
      }
    );
  };
  if ($@) {
    croak "Failed to add collaborator ";
  }
  
  my $rep = $dbi->model('project')->select(
    'id',
    where => {
      'row_id' => $rproject,
    }
  )->value;

  return $rep;
}
1;
