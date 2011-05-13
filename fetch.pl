#!/usr/bin/perl

$PWD = $ENV{PWD};

# さいしょに, master に含まれている commit を得る。
# FIXME: Make sure index is clean.
($ch) = `git show-ref refs/heads/master` =~ /([0-9a-f]{40,})/;
system("git read-tree --reset $ch") && die;
open($F, "git ls-tree $ch |") || die;
while (<$F>) {
    next unless /^160000\s+commit\s+([0-9a-f]{40,})\s+(\S+)/;
    $h = $1;
    $repo = $2;
    push(@repos, $repo);
    $master_hash{$repo} = $h;
    print "$h $repo\n";
    chdir("$PWD/$repo");
#    &get_commit($h);
#    &get_commits($repo);
    chdir($PWD);
}
close($F);

# 次に、各リポジトリ候補から結果を得て回る。
open($F, "find -depth -mindepth 2 -maxdepth 2 -type d -name .git |") || die;
while (<$F>) {
    print;
    chomp;
    s=^\./==;
    next unless m@^(.+)/\.git$@;
    print "*$1\n";
    chdir("$PWD/$1") || die $1;
    &get_commits($1);
    chdir($PWD);
}
close($F);

# write!
for $r (sort {$a <=> $b} keys %revs) {
    for $h (@{$revs{$r}}) {
        $msg = $commits{$h}{MSG};
        for (grep(/^GIT_/, keys %{$commits{$h}})) {
            $ENV{$_} = $commits{$h}{$_};
        }
        my $repo = $commits{$h}{REPO};
        system("git update-index --add --cacheinfo 160000 $h $repo\n")
            && die;
        if ($master_hash{$repo} eq '') {
            my $gitm = '';
            my ($mode, $mh)
                = `git ls-tree $ch .gitmodules`
                =~ /^(\d+)\s+blob\s+([0-9a-f]{40,})/;
            if ($mh eq '') {
                $mode = '100644';
            } else {
                $gitm = `git cat-file blob $mh`;
            }
            open($F, "| git hash-object -w --stdin > .git/_.bak") || die;
            $X = $repo;
            $X = "LLVM" if $X eq 'llvm';
            print $F "$gitm\[submodule \"$repo\"]\n\tpath = $repo\n\turl = git\@github.com:chapuni/$X.git\n";
            close($F);
            $mh = `cat .git/_.bak`;
            chomp $mh;
            system("git update-index --add --cacheinfo $mode $mh .gitmodules")
                && die;
            $master_hash{$repo} = $ch;
        }
    }
    open($F, "git write-tree |") || die;
    my $th = <$F>;
    chomp $th;
    close($F);
    open($F, "| git commit-tree $th -p $ch > .git/_.bak") || die "<$ch $th>";
    print $F "[r$r]$msg";
    close($F);
    $ch = `cat .git/_.bak`;
    chomp $ch;
    print "r$r:$ch\n";
}

die "Completed die!";

sub get_commits
{
    my ($dir) = @_;
    my $F;
    my $a;
    my $head = $master_hash{$dir};
    #die unless $commits{$head};
    open($F, "git show-ref master |") || die;
    while (<$F>) {
        next unless /^([0-9a-f]{40,})\s+(\S+)/;
        #print "$1($2)\n";
        if ($head ne '') {
            $a .= " $master_hash{$dir}..$1";
        } else {
            $a .= " $1";
        }
    }
    print "refs: $a\n";
    close($F);
    my $f = 0;
    open($F, "git log --pretty=raw $a |") || die;
    while (<$F>) {
        if ($f) {
            if (/^(\w+)\s+([0-9a-f]{40,})/) {
                $commits{$h}{$1} = $2;
            } elsif (/^(\w+)\s+(.*)\s+<(.+)>\s+(\d[^\r\n]*)/) {
                $commits{$h}{"GIT_".uc($1)."_NAME"} = $2;
                $commits{$h}{"GIT_".uc($1)."_EMAIL"} = $3;
                $commits{$h}{"GIT_".uc($1)."_DATE"} = $4;
            } else {
                die "XXX: $_" unless /^\s*$/;
                $f = 0;
                $msg = '';
            }
        } else {
            if (/^commit\s+([0-9a-f]{40,})/) {
                $h = $1;
                $f = 1;
                last if $commits{$h};
                $commits{$h}{REPO} = $dir;
                next;
            } elsif (/^    (\s*)$/) {
                $msg .= $1;
                next;
            } elsif (/git-svn-id:.+\@(\d+)/) {
                print "$dir $h r$1\n" unless $1 % 1000;
                $commits{$h}{REV} = $1;
                push(@{$revs{$1}}, $h);
                next;
            } elsif (/^    (.*)$/) {
                $commits{$h}{MSG} .= $msg . $1;
                $msg = '';
            }
        }
    }
    close($F);
}

sub get_commit
{
    my ($h) = @_;
    my $F;
    my %c = ();
    open($F, "git cat-file commit $h |") || die;
    while (<$F>) {
        chomp;
        if (/^(\w+)\s+(.*)/) {
            $c{$1} = $2;
        } elsif (/^$/) {
            last;
        } else {
            die;
        }
    }
    my @msg = <$F>;
    close($F);

    if ($msg[$#msg] =~/git-svn-id:.+\@(\d+)/) {
        printf "rev:$1\n";
        pop(@msg);
    }
    while ($msg[$#msg] =~/^[\r\n]*$/) {
        pop(@msg);
        die unless @msg > 0;
    }
    $c{'msg'} = join('', @msg);
    $commits{$h} = {%c};
    return %c;
}

#EOF
