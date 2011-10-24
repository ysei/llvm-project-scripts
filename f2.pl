#!/usr/bin/perl

use FileHandle;
use IPC::Open2;

$verbose++ if grep(/VERBOSE/, @ARGV);
$json++ if grep(/JSON/, @ARGV);

$m_master = 'm/master';
$t_master = 't/master';

# 現在の refs をすべて取得。
open($F, "git show-ref |") || die;
while (<$F>) {
	chomp;
	if (m=^([0-9a-f]{40})\s+refs/remotes/llvm.org/([^/]+)/master$=) {
		$repos{$2} = $1;
		$branches{'master'}{$2} = $1;
	} elsif (m=^([0-9a-f]{40})\s+refs/remotes/llvm.org/([^/]+)/([^/]+)$=) {
		$branches{$3}{$2} = $1;
		push(@branch_names, $3);
	} elsif (m=^[0-9a-f]{40}\s+refs/tags/([rt])(\d+)$=) {
		$tags{$2} .= " $1$2";
	} elsif (m=^([0-9a-f]{40})\s+refs/heads/(m/[^/]+)$=) {
		# 各 submodule の最終 commit を得る。
		$last{$2} = $1;
	}
}
close($F);

@dt = sort {$a <=> $b} keys %tags;
if (@dt > 2048) {
	system('git tag -d ' . join(' ', @tags{@dt[0..$#dt - 1024]})) && die;
}

########

($hash_subm, $subm, $tree, @revs) = &read_subm_commits($last{'m/master'}, 'master');
$hash_tree = '';
if ($hash_subm ne '') {
	$hash_tree = $dic_tree{$dic_revs{$hash_subm}};
}

if (@revs > 0) {
	&read_revs;
	&commit_revs('master', $hash_subm, $subm, $hash_tree, $tree, @revs);
}

$os = $subm;

@branch_names = qw(release_30);

for $branch (@branch_names) {
	print STDERR "**** Branch: $branch ****\n" if $verbose;
	($hash_subm, $subm, $tree, @revs) = &read_subm_commits($last{"m/$branch"}, $branch, $os);
	$hash_tree = '';
	if ($hash_subm ne '') {
		$hash_tree = $dic_tree{$dic_revs{$hash_subm}};
	}

	if (@revs > 0) {
		&read_revs;
		&commit_revs($branch, $hash_subm, $subm, $hash_tree, $tree, @revs);
	}
}

exit;	################################################################

sub read_revs {
	return if $REVLOG;

	eval "require 'revs.pl'";

	@m_revs = sort {$a <=> $b} keys %dic_subm;

	if (scalar(@m_revs) != scalar(keys %dic_revs)) {
		open($REVLOG, "> revs.pl") || die;
		for my $r (@m_revs) {
			&revlog($REVLOG, $r, $dic_subm{$r}, $dic_tree{$r})
		}
		close($REVLOG);
	}

	open($REVLOG, ">> revs.pl") || die;
}

sub read_subm_commits {
	my ($hash, $branch, $base) = @_;
	@revs = ();
	my $subm;
	my $tree;

	while (1) {
		($subm, $tree) = &readtree($hash);

		my $upd = 0;
		while (my ($repo, $h) = each %{$branches{$branch}}) {
			if ($h eq $subm->{$repo}{H}) {
				print STDERR "$repo=$h (up-to-date)\n" if $verbose;
				next;
			}
			if ($subm->{$repo}{H} ne '') {
				print STDERR "$repo=$subm->{$repo}{H}..$h\n" if $verbose;
				$commits{$repo} = {};
				&get_commits2($commits{$repo}, $subm->{$repo}{H}, $h);
				$branches{$branch}{$repo} = $subm->{$repo}{H};
			} else {
				print STDERR "$repo=$base->{$repo}{H}..$h\n" if $verbose;
				$commits{$repo} = {};
				&get_commits2($commits{$repo}, $base->{$repo}{H}, $h);
				die unless ($base->{$repo}{H} ne '');
				$branches{$branch}{$repo} = $base->{$repo}{H};
			}
			push(@revs, keys %{$commits{$repo}});
			$upd++;
		}

		my %t;
		@t{@revs} = @revs;
		@revs = sort {$a <=> $b} keys %t;

		last if $upd == 0 || $hash eq '';

		&read_revs;

		# 得るべき revision が既知のものより古い場合は作り直し。
		if ($revs[0] <= $m_revs[0]) {
			$hash = '';
			next;
		}

		# Great Linear Search
		die if $hash eq '';
		die $hash unless defined $dic_revs{$hash};
		while ($dic_revs{$hash} >= $revs[0]) {
			$hash = &sb_hash("git rev-list --no-walk --first-parent $hash^");
			die unless defined $dic_revs{$hash};
		}
	}

	return ($hash, $subm, $tree, @revs);
}

sub readtree {
	my ($commit) = @_;
	$tree = {};
	$subm = {};
	return if $commit eq '';
	open(my $F, "git ls-tree $commit |") || die;
	while (<$F>) {
		if (/^100644 blob ([0-9a-f]{40})\s+\.gitmodules$/) {
			$subm->{'.gitmodules'}{B} = $1;
			next;
		}
		next unless my ($h, $repo) = /^160000 commit ([0-9a-f]{40})\s+(\S+)/;
		$subm->{$repo}{H} = $h;
		`git cat-file commit $h` =~ /^tree\s+([0-9a-f]{40})/;
		$tree->{$repo}{T} = $1;
	}
	close($F);
	return ($subm, $tree);
}

# 書きだす!
sub commit_revs {
	my ($branch, $parent_subm, $subm, $parent, $tree, @revs) = @_;
	
	for my $rev (@revs) {
		my $msg = '';
		my @mergebase_subm = ();
		my @mergebase_tree = ();
		push(@mergebase_subm, $parent_subm) if $parent_subm ne '';
		push(@mergebase_tree, $parent) if $parent ne '';
		for my $repo (sort keys %{$branches{$branch}}) {
			my $r = $commits{$repo}{$rev};
			next unless defined $r;
			while (my ($k, $v) = each %$r) {
				if ($k =~ /^GIT_/) {
					$ENV{$k} = $v;
				} elsif ($k eq 'MSG') {
					die unless ($msg eq '' || $msg eq $v);
					$msg = $v;
				}
			}
			if (!defined $subm->{$repo}{H}) {
				&update_gitmodules($subm, $repo);

				# branch 始点の場合。
				if (defined $r->{parent}) {
					my $p = {};
					&get_commits2($p, "$r->{parent}^", $r->{parent});
					my @pr = keys %$p;
					die unless @pr == 1;
					die unless defined $dic_subm{$pr[0]};
					die unless defined $dic_tree{$pr[0]};
					push(@mergebase_subm, $dic_subm{$pr[0]});
					push(@mergebase_tree, $dic_tree{$pr[0]});
				}
			}
			$tree->{$repo}{T} = $r->{tree};
			$subm->{$repo}{H} = $r->{commit};
		}

		# Subtree
		$parent = &make_commit($tree, $msg, @mergebase_tree);
		print STDERR "t $parent $rev $ENV{GIT_AUTHOR_NAME}\n" if $verbose;

		$parent_subm = &make_commit($subm, $msg, @mergebase_subm);
		print STDERR "m $parent_subm $rev $ENV{GIT_AUTHOR_NAME}\n" if $verbose;

		&revlog($REVLOG, $rev, $parent_subm, $parent);

		if ((++$nrevs & 255) == 0 || $rev >= $revs[$#revs - 100]) {
			system("git update-ref refs/tags/t$rev $parent") && die;
			system("git update-ref refs/heads/t/$branch $parent") && die;
			system("git update-ref refs/tags/r$rev $parent_subm") && die;
			system("git update-ref refs/heads/m/$branch $parent_subm") && die;
		}

		&json($branch, $rev, $msg, $parent);
	}
}

sub json {
	my ($branch, $rev, $msg, $hash_tree) = @_;
	my %js = (branch=>$branch,
			  project=>'llvm-project');
	$js{'revision'} = "r$rev";
	$js{'repository'} = 'git://github.com/chapuni/llvm-project';
	$ENV{GIT_AUTHOR_DATE} =~ /^(\d+)/;
	$js{'when'} = $1;
	$js{'who'} = sprintf("%s <%s>",
						 $ENV{GIT_AUTHOR_NAME},
						 $ENV{GIT_AUTHOR_EMAIL});
	$js{'comments'} = $msg;

	open(my $df, "git diff-tree --numstat $hash_tree |");
	$js{'files'} = '['.join(',',join(',', grep(s=^\d+\s+\d+\s+(.*)\r*\n*$=\"\1\"=, <$df>))).']';
	close($df);

	for (sort keys %js) {
		#print STDERR "$_=<$js{$_}>\n" if $verbose;
		my @a = split(//, $js{$_});
		for (@a) {
			if ($_ eq ' ') {
				$_ = '+';
			} elsif (/^\r*\n$/) {
				$_ = '%0A';
			} elsif (/^[-0-9A-Z_a-z]$/) {
			} else {
				$_ = sprintf('%%%02X', ord);
			}
		}
		$js{$_} = join('', @a);
	}
	open(my $fj, "> _.bak") || die;
	print $fj join('&', map {"$_=$js{$_}"} sort keys %js);
	close($fj);
	system('wget http://bb.pgr.jp/change_hook/base --post-file=_.bak')
		if $json;
}

sub revlog {
	my ($REVLOG, $rev, $subm, $subt) = @_;
	print $REVLOG "\$dic_subm{$rev}=\$s='$subm';";
	print $REVLOG "\$dic_tree{$rev}=\$t='$subt';";
	print $REVLOG "\$dic_revs{\$s}=\$dic_revs{\$t}=$rev;\n";
}

sub update_gitmodules {
	my ($subm, $repo) = @_;
	my $gm = $subm->{'.gitmodules'};
	$gm->{blob} =`git cat-file blob $gm->{B}`
		if ($gm->{blob} eq '' && $gm->{B} ne '');
	$gm->{blob} .= "[submodule \"$repo\"]\n";
	$gm->{blob} .= "\tpath = $repo\n";
	$gm->{blob} .= "\turl = http://llvm.org/git/$repo.git\n";
	$gm->{B} = &sb_hash("git hash-object -w --stdin", $gm->{blob});
	$subm->{'.gitmodules'} = $gm;
}

sub make_commit {
	my ($tree, $msg, @parents) = @_;
	my $mktree = sub {
		my ($F) = @_;
		for my $repo (sort keys %$tree) {
			if ($tree->{$repo}{B} ne '') {
				print $F "100644 blob $tree->{$repo}{B}\t$repo\n";
			} elsif ($tree->{$repo}{T} ne '') {
				print $F "040000 tree $tree->{$repo}{T}\t$repo\n";
			} elsif ($tree->{$repo}{H} ne '') {
				print $F "160000 commit $tree->{$repo}{H}\t$repo\n";
			}
		}
	};
	my @tree = &subprocess("git mktree", $mktree);
	my $tree_hash = shift @tree;
	chomp $tree_hash;
	my $parent = join(' ', map{"-p ".$_} @parents);
	return &sb_hash("git commit-tree $tree_hash $parent", $msg);
}

sub subprocess {
	my ($cmd, $writer_proc) = @_;
	pipe(R, W) || die;
	my $pid = fork();
	if (!$pid) {
		open(STDOUT, ">&W") || die;
		close(R);
		open(my $F, "| " . $cmd) || die;
		$writer_proc->($F);
		close($F);
		exit 0;
	}
	close(W);
	my @r = <R>;
	close R;
	wait;
	return @r;
}

sub sb_hash {
	my ($cmd, $stdin) = @_;
	my $cb = sub {
		my $F = shift @_;
		print $F $stdin;
	};
	my @r = &subprocess($cmd, $cb);
	my $r = shift @r;
	chomp $r;
	return $r;
}

sub get_commits2 {
	my ($commits, $min, $h) = @_;
	return if $min eq $h;
	if ($min ne '') {
		$h = "$min..$h";
	}
	open(my $F, "git log --pretty=raw --decorate=no $h |") || die;
	my @cm = ();
	my $t;
	while (<$F>) {
		if (@cm > 0 && /^commit\s+([0-9a-f]{40})/) {
			$t = &parse_commit(@cm);
			$commits->{$t->{REV}} = $t;
			@cm = ();
		}
		chomp;
		push(@cm, $_);
	}
	if (@cm > 0) {
		$t = &parse_commit(@cm);
		$commits->{$t->{REV}} = $t;
	}
}

sub parse_commit {
	my %r = ();
	my @t = ();
	local $_;
	while ($_ = shift @_) {
		if (/^$/) {
			last;
		} elsif (/^(\w+)\s+(.+)\s+<(.+)>\s+(\d+)(\s+\+\d{4})?$/) {
			$r{$1} = "$2 <$3> $4$5";
			$r{"GIT_".uc($1)."_NAME"} = $2;
			$r{"GIT_".uc($1)."_EMAIL"} = $3;
			$r{"GIT_".uc($1)."_DATE"} = $4.$5;
		} elsif (/^(\w+)\s+([0-9a-f]{40})$/) {
			$r{$1} = $2;
		} else {
			die "$_";
		}
	}
	while ($_ = shift @_) {
		if (/git-svn-id:\s+\S+@(\d+)/) {
			$r{REV} = $1;
			last;
		} elsif (/^\s\s\s\s(.*)/) {
			push(@t, "$1\n");
		} else {
			die $_;
		}
	}
	while (@t > 0 && $t[$#t] =~ /^[\r\n]+$/) {
		pop(@t);
	}
	$r{MSG} = join('', @t);
	return \%r;
}

#	Local Variables:
#		tab-width: 4;
#	End:
#EOF
