=head1 NAME

 Servers::httpd::apache_itk - i-MSCP Apache2/ITK Server implementation

=cut

# i-MSCP - internet Multi Server Control Panel
# Copyright (C) 2010-2015 by internet Multi Server Control Panel
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

package Servers::httpd::apache_itk;

use strict;
use warnings;
no if $] >= 5.017011, warnings => 'experimental::smartmatch';
use iMSCP::Debug;
use iMSCP::Database;
use iMSCP::EventManager;
use iMSCP::Config;
use iMSCP::Execute;
use iMSCP::TemplateParser;
use iMSCP::File;
use iMSCP::Dir;
use iMSCP::Ext2Attributes qw(setImmutable clearImmutable isImmutable);
use iMSCP::Rights;
use iMSCP::Net;
use iMSCP::ProgramFinder;
use iMSCP::Service;
use File::Temp;
use File::Basename;
use Scalar::Defer;
use version;
use parent 'Common::SingletonClass';

=head1 DESCRIPTION

 i-MSCP Apache2/ITK Server implementation.

=head1 PUBLIC METHODS

=over 4

=item registerSetupListeners(\%eventManager)

 Register setup event listeners

 Param iMSCP::EventManager \%eventManager
 Return int 0 on success, other on failure

=cut

sub registerSetupListeners
{
	my (undef, $eventManager) = @_;

	require Servers::httpd::apache_itk::installer;
	Servers::httpd::apache_itk::installer->getInstance()->registerSetupListeners($eventManager);
}

=item preinstall()

 Process preinstall tasks

 Return int 0 on success, other on failure

=cut

sub preinstall
{
	my $self = shift;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdPreInstall', 'apache_itk');
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterHttpdPreInstall', 'apache_itk');
}

=item install()

 Process install tasks

 Return int 0 on success, other on failure

=cut

sub install
{
	my $self = shift;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdInstall', 'apache_itk');
	return $rs if $rs;

	require Servers::httpd::apache_itk::installer;
	$rs = Servers::httpd::apache_itk::installer->getInstance()->install();
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterHttpdInstall', 'apache_itk');
}

=item postinstall()

 Process postinstall tasks

 Return int 0 on success, other on failure

=cut

sub postinstall
{
	my $self = shift;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdPostInstall', 'apache_itk');
	return $rs if $rs;

	iMSCP::Service->getInstance()->enable($self->{'config'}->{'HTTPD_SNAME'});

	$self->{'eventManager'}->register(
		'beforeSetupRestartServices', sub { push @{$_[0]}, [ sub { $self->restart(); }, 'Httpd (Apache)' ]; 0; }
	);

	$self->{'eventManager'}->trigger('afterHttpdPostInstall', 'apache_itk');
}

=item uninstall()

 Process uninstall tasks

 Return int 0 on success, other on failure

=cut

sub uninstall
{
	my $self = shift;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdUninstall', 'apache_itk');
	return $rs if $rs;

	require Servers::httpd::apache_itk::uninstaller;
	$rs = Servers::httpd::apache_itk::uninstaller->getInstance()->uninstall();
	return $rs if $rs;

	$rs = $self->{'eventManager'}->trigger('afterHttpdUninstall', 'apache_itk');
	return $rs if $rs;

	$self->restart();
}

=item setEnginePermissions()

 Set engine permissions

 Return int 0 on success, other on failure

=cut

sub setEnginePermissions
{
	my $self = shift;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdSetEnginePermissions');
	return $rs if $rs;

	require Servers::httpd::apache_itk::installer;
	$rs = Servers::httpd::apache_itk::installer->getInstance()->setEnginePermissions();
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterHttpdSetEnginePermissions');
}

=item addUser(\%data)

 Process addUser tasks

 Param hash \%data User data
 Return int 0 on success, other on failure

=cut

sub addUser
{
	my ($self, $data) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdAddUser', $data);
	return $rs if $rs;

	$self->setData($data);

	$rs = iMSCP::SystemUser->new( username => $self->getRunningUser() )->addToGroup($data->{'GROUP'});
	return $rs if $rs;

	$self->{'restart'} = 1;

	$self->flushData();

	$self->{'eventManager'}->trigger('afterHttpdAddUser', $data);
}

=item deleteUser(\%data)

 Process deleteUser tasks

 Param hash \%data User data
 Return int 0 on success, other on failure

=cut

sub deleteUser
{
	my ($self, $data) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdDelUser', $data);
	return $rs if $rs;

	$rs = iMSCP::SystemUser->new( username => $self->getRunningUser() )->removeFromGroup($data->{'GROUP'});
	return $rs if $rs;

	$self->{'restart'} = 1;

	$self->{'eventManager'}->trigger('afterHttpdDelUser', $data);
}

=item addDmn(\%data)

 Process addDmn tasks

 Param hash \%data Domain data
 Return int 0 on success, other on failure

=cut

sub addDmn
{
	my ($self, $data) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdAddDmn', $data);
	return $rs if $rs;

	$self->setData($data);

	$rs = $self->_addCfg($data);
	return $rs if $rs;

	$rs = $self->_addFiles($data);
	return $rs if $rs;

	$self->{'restart'} = 1;

	$self->flushData();

	$self->{'eventManager'}->trigger('afterHttpdAddDmn', $data);
}

=item restoreDmn(\%data)

 Process restoreDmn tasks

 Param hash \%data Domain data
 Return int 0 on success, other on failure

=cut

sub restoreDmn
{
	my ($self, $data) = @_;

	$self->setData($data);

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdRestoreDmn', $data);
	return $rs if $rs;

	$rs = $self->_addFiles($data);
	return $rs if $rs;

	$self->flushData();

	$self->{'eventManager'}->trigger('afterHttpdRestoreDmn', $data);
}

=item disableDmn(\%data)

 Process disableDmn tasks

 Param hash \%data Domain data
 Return int 0 on success, other on failure

=cut

sub disableDmn
{
	my ($self, $data) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdDisableDmn', $data);
	return $rs if $rs;

	$self->setData($data);

	my $ipMngr = iMSCP::Net->getInstance();

	my $version = $self->{'config'}->{'HTTPD_VERSION'};

	$self->setData(
		{
			BASE_SERVER_VHOST => $main::imscpConfig{'BASE_SERVER_VHOST'},
			AUTHZ_ALLOW_ALL => (version->parse($version) >= version->parse('2.4.0'))
				? 'Require all granted' : 'Allow from all',
			HTTPD_LOG_DIR => $self->{'config'}->{'HTTPD_LOG_DIR'},
			DOMAIN_IP => ($ipMngr->getAddrVersion($data->{'DOMAIN_IP'}) eq 'ipv4')
				? $data->{'DOMAIN_IP'} : "[$data->{'DOMAIN_IP'}]",
		}
	);

	my %configTpls = ( '' => 'domain_disabled.tpl' );

	if($data->{'SSL_SUPPORT'}) {
		$self->setData({ CERTIFICATE => "$main::imscpConfig{'GUI_ROOT_DIR'}/data/certs/$data->{'DOMAIN_NAME'}.pem" });
		$configTpls{'_ssl'} =  'domain_disabled_ssl.tpl';
	}

	for my $configTplType(keys %configTpls) {
		$rs = $self->buildConfFile(
			"$self->{'apacheTplDir'}/$configTpls{$configTplType}",
			$data,
			{ destination => "$self->{'apacheWrkDir'}/$data->{'DOMAIN_NAME'}$configTplType.conf" }
		);
		return $rs if $rs;

		$rs = $self->installConfFile("$data->{'DOMAIN_NAME'}$configTplType.conf");
		return $rs if $rs;
	}

	$self->{'restart'} = 1;

	$self->flushData();

	$self->{'eventManager'}->trigger('afterHttpdDisableDmn', $data);
}

=item deleteDmn(\%data)

 Process deleteDmn tasks

 Param hash \%data Domain data
 Return int 0 on success, other on failure

=cut

sub deleteDmn
{
	my ($self, $data) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdDelDmn', $data);
	return $rs if $rs;

	# Disable apache2 domain vhost files
	for my $conffile("$data->{'DOMAIN_NAME'}.conf", "$data->{'DOMAIN_NAME'}_ssl.conf") {
		if (-f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$conffile") {
			$rs = $self->disableSites($conffile);
			return $rs if $rs;
		}
	}

	# Remove apache2 domain vhost files
	for my $conffile(
		"$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}.conf",
		"$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}_ssl.conf",
		"$self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/$data->{'DOMAIN_NAME'}.conf",
		"$self->{'apacheWrkDir'}/$data->{'DOMAIN_NAME'}.conf",
		"$self->{'apacheWrkDir'}/$data->{'DOMAIN_NAME'}_ssl.conf"
	) {
		if(-f $conffile) {
			$rs = iMSCP::File->new( filename => $conffile )->delFile();
			return $rs if $rs;
		}
	}

	# Remove Web folder directory (only if it is not shared with another domain)
	unless($data->{'SHARED_MOUNT_POINT'} || ! -d $data->{'WEB_DIR'}) {
		(my $userWebDir = $main::imscpConfig{'USER_WEB_DIR'}) =~ s%/+$%%;
		my $parentDir = dirname($data->{'WEB_DIR'});

		clearImmutable($parentDir);
		clearImmutable($data->{'WEB_DIR'}, 'recursive');

		$rs = iMSCP::Dir->new( dirname => $data->{'WEB_DIR'} )->remove();
		return $rs if $rs;

		if($parentDir ne $userWebDir) {
			my $dir = iMSCP::Dir->new( dirname => $parentDir );

			if($dir->isEmpty()) {
				clearImmutable(dirname($parentDir));

				$rs = $dir->remove();
				return $rs if $rs;
			}
		}

		if($data->{'WEB_FOLDER_PROTECTION'} eq 'yes' && $parentDir ne $userWebDir) {
			do {
				setImmutable($parentDir) if -d $parentDir;
			} while (($parentDir = dirname($parentDir)) ne $userWebDir);
		}
	}

	# Remove log directory if any
	$rs = iMSCP::Dir->new( dirname => "$self->{'config'}->{'HTTPD_LOG_DIR'}/$data->{'DOMAIN_NAME'}" )->remove();
	return $rs if $rs;

	$self->{'restart'} = 1;

	$self->{'eventManager'}->trigger('afterHttpdDelDmn', $data);
}

=item addSub(\%data)

 Process addSub tasks

 Param hash \%data Subdomain data
 Return int 0 on success, other on failure

=cut

sub addSub
{
	my ($self, $data) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdAddSub', $data);
	return $rs if $rs;

	$self->setData($data);

	$rs = $self->_addCfg($data);
	return $rs if $rs;

	$rs = $self->_addFiles($data);
	return $rs if $rs;

	$self->{'restart'} = 1;

	$self->flushData();

	$self->{'eventManager'}->trigger('afterHttpdAddSub', $data);
}

=item restoreSub(\%data)

 Process restoreSub tasks

 Param hash \%data Subdomain data
 Return int 0 on success, other on failure

=cut

sub restoreSub
{
	my ($self, $data) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdRestoreSub', $data);
	return $rs if $rs;

	$self->setData($data);

	$rs = $self->_addFiles($data);
	return $rs if $rs;

	$self->flushData();

	$self->{'eventManager'}->trigger('afterHttpdRestoreSub', $data);

	0;
}

=item disableSub(\%data)

 Process disableSub tasks

 Param hash \%data Subdomain data
 Return int 0 on success, other on failure

=cut

sub disableSub
{
	my ($self, $data) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdDisableSub', $data);
	return $rs if $rs;

	$rs = $self->disableDmn($data);
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterHttpdDisableSub', $data);
}

=item deleteSub(\%data)

 Process deleteSub tasks

 Param hash \%data Subdomain data
 Return int 0 on success, other on failure

=cut

sub deleteSub
{
	my ($self, $data) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdDelSub', $data);

	$rs = $self->deleteDmn($data);
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterHttpdDelSub', $data);
}

=item AddHtuser(\%data)

 Process AddHtuser tasks

 Param hash \%data Htuser data
 Return int 0 on success, other on failure

=cut

sub addHtuser
{
	my ($self, $data) = @_;

	my $webDir = $data->{'WEB_DIR'};
	my $fileName = $self->{'config'}->{'HTACCESS_USERS_FILENAME'};
	my $filePath = "$webDir/$fileName";

	# Unprotect root Web directory
	clearImmutable($webDir);

	my $file = iMSCP::File->new( filename => $filePath );
	my $fileContent = $file->get() if -f $filePath;
	$fileContent = '' unless defined $fileContent;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdAddHtuser', \$fileContent, $data);
	return $rs if $rs;

	$fileContent =~ s/^$data->{'HTUSER_NAME'}:[^\n]*\n//gim;
	$fileContent .= "$data->{'HTUSER_NAME'}:$data->{'HTUSER_PASS'}\n";

	$rs = $self->{'eventManager'}->trigger('afterHttpdAddHtuser', \$fileContent, $data);
	return $rs if $rs;

	$rs = $file->set($fileContent);
	return $rs if $rs;

	$rs = $file->save();
	return $rs if $rs;

	$rs = $file->mode(0640);
	return $rs if $rs;

	$rs = $file->owner($main::imscpConfig{'ROOT_USER'}, $data->{'GROUP'});
	return $rs if $rs;

	# Protect root Web directory if needed
	setImmutable($webDir) if $data->{'WEB_FOLDER_PROTECTION'} eq 'yes';

	0;
}

=item deleteHtuser(\%data)

 Process deleteHtuser tasks

 Param hash \%data Htuser data
 Return int 0 on success, other on failure

=cut

sub deleteHtuser
{
	my ($self, $data) = @_;

	my $webDir = $data->{'WEB_DIR'};
	my $fileName = $self->{'config'}->{'HTACCESS_USERS_FILENAME'};
	my $filePath = "$webDir/$fileName";

	# Unprotect root Web directory
	clearImmutable($webDir);

	my $file = iMSCP::File->new( filename => $filePath );
	my $fileContent = $file->get() if -f $filePath;
	$fileContent = '' unless defined $fileContent;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdDelHtuser', \$fileContent, $data);
	return $rs if $rs;

	$fileContent =~ s/^$data->{'HTUSER_NAME'}:[^\n]*\n//gim;

	$rs = $self->{'eventManager'}->trigger('afterHttpdDelHtuser', \$fileContent, $data);
	return $rs if $rs;

	$rs = $file->set($fileContent);
	return $rs if $rs;

	$rs = $file->save();
	return $rs if $rs;

	$rs = $file->mode(0640);
	return $rs if $rs;

	$rs = $file->owner($main::imscpConfig{'ROOT_USER'}, $data->{'GROUP'});
	return $rs if $rs;

	# Protect root Web directory if needed
	setImmutable($webDir) if $data->{'WEB_FOLDER_PROTECTION'} eq 'yes';

	0;
}

=item addHtgroup(\%data)

 Process addHtgroup tasks

 Param hash \%data Htgroup data
 Return int 0 on success, other on failure

=cut

sub addHtgroup
{
	my ($self, $data) = @_;

	my $webDir = $data->{'WEB_DIR'};
	my $fileName = $self->{'config'}->{'HTACCESS_GROUPS_FILENAME'};
	my $filePath = "$webDir/$fileName";

	# Unprotect root Web directory
	clearImmutable($webDir);

	my $file = iMSCP::File->new( filename => $filePath );
	my $fileContent = $file->get() if -f $filePath;
	$fileContent = '' unless defined $fileContent;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdAddHtgroup', \$fileContent, $data);
	return $rs if $rs;

	$fileContent =~ s/^$data->{'HTGROUP_NAME'}:[^\n]*\n//gim;
	$fileContent .= "$data->{'HTGROUP_NAME'}:$data->{'HTGROUP_USERS'}\n";

	$rs = $self->{'eventManager'}->trigger('afterHttpdAddHtgroup', \$fileContent, $data);
	return $rs if $rs;

	$rs = $file->set($fileContent);
	return $rs if $rs;

	$rs = $file->save();
	return $rs if $rs;

	$rs = $file->mode(0640);
	return $rs if $rs;

	$rs = $file->owner($main::imscpConfig{'ROOT_USER'}, $data->{'GROUP'});
	return $rs if $rs;

	# Protect root Web directory if needed
	setImmutable($webDir) if $data->{'WEB_FOLDER_PROTECTION'} eq 'yes';

	0;
}

=item deleteHtgroup(\%data)

 Process deleteHtgroup tasks

 Param hash \%data Htgroup data
 Return int 0 on success, other on failure

=cu

sub deleteHtgroup
{
	my ($self, $data) = @_;

	my $webDir = $data->{'WEB_DIR'};
	my $fileName = $self->{'config'}->{'HTACCESS_GROUPS_FILENAME'};
	my $filePath = "$webDir/$fileName";

	# Unprotect root Web directory
	clearImmutable($webDir);

	my $file = iMSCP::File->new( filename => $filePath );
	my $fileContent = $file->get() if -f $filePath;
	$fileContent = '' unless defined $fileContent;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdDelHtgroup', \$fileContent, $data);
	return $rs if $rs;

	$fileContent =~ s/^$data->{'HTGROUP_NAME'}:[^\n]*\n//gim;

	$rs = $file->set($fileContent);
	return $rs if $rs;

	$rs = $self->{'eventManager'}->trigger('afterHttpdDelHtgroup', \$fileContent, $data);
	return $rs if $rs;

	$rs = $file->save();
	return $rs if $rs;

	$rs = $file->mode(0640);
	return $rs if $rs;

	$rs = $file->owner($main::imscpConfig{'ROOT_USER'}, $data->{'GROUP'});
	return $rs if $rs;

	# Protect root Web directory if needed
	setImmutable($webDir) if $data->{'WEB_FOLDER_PROTECTION'} eq 'yes';

	0;
}

=item addHtaccess(\%data)

 Process addHtaccess tasks

 Param hash \%data Htaccess data
 Return int 0 on success, other on failure

=cut

sub addHtaccess
{
	my ($self, $data) = @_;

	# Here we process only if AUTH_PATH directory exists
	# Note: It's temporary fix for 1.1.0-rc2 (See #749)
	if(-d $data->{'AUTH_PATH'}) {
		my $fileUser = "$data->{'HOME_PATH'}/$self->{'config'}->{'HTACCESS_USERS_FILENAME'}";
		my $fileGroup = "$data->{'HOME_PATH'}/$self->{'config'}->{'HTACCESS_GROUPS_FILENAME'}";
		my $filePath = "$data->{'AUTH_PATH'}/.htaccess";

		my $file = iMSCP::File->new( filename => $filePath );
		my $fileContent = $file->get() if -f $filePath;
		$fileContent = '' unless defined $fileContent;

		my $rs = $self->{'eventManager'}->trigger('beforeHttpdAddHtaccess', \$fileContent, $data);
		return $rs if $rs;

		my $bTag = "### START i-MSCP PROTECTION ###\n";
		my $eTag = "### END i-MSCP PROTECTION ###\n";
		my $tagContent = "AuthType $data->{'AUTH_TYPE'}\nAuthName \"$data->{'AUTH_NAME'}\"\nAuthUserFile $fileUser\n";

		if($data->{'HTUSERS'} eq '') {
			$tagContent .= "AuthGroupFile $fileGroup\nRequire group $data->{'HTGROUPS'}\n";
		} else {
			$tagContent .= "Require user $data->{'HTUSERS'}\n";
		}

		$fileContent = replaceBloc($bTag, $eTag, '', $fileContent);
		$fileContent = $bTag . $tagContent . $eTag . $fileContent;

		$rs = $self->{'eventManager'}->trigger('afterHttpdAddHtaccess', \$fileContent, $data);
		return $rs if $rs;

		$rs = $file->set($fileContent);
		return $rs if $rs;

		$rs = $file->save();
		return $rs if $rs;

		$rs = $file->mode(0640);
		return $rs if $rs;

		$file->owner($data->{'USER'}, $data->{'GROUP'});
	} else {
		0;
	}
}

=item deleteHtaccess(\%data)

 Process deleteHtaccess tasks

 Param hash \%data Htaccess data
 Return int 0 on success, other on failure

=cut

sub deleteHtaccess
{
	my ($self, $data) = @_;

	# Here we process only if AUTH_PATH directory exists
	# Note: It's temporary fix for 1.1.0-rc2 (See #749)
	if(-d $data->{'AUTH_PATH'}) {
		my $fileUser = "$data->{'HOME_PATH'}/$self->{'config'}->{'HTACCESS_USERS_FILENAME'}";
		my $fileGroup = "$data->{'HOME_PATH'}/$self->{'config'}->{'HTACCESS_GROUPS_FILENAME'}";
		my $filePath = "$data->{'AUTH_PATH'}/.htaccess";

		my $file = iMSCP::File->new( filename => $filePath );
		my $fileContent = $file->get() if -f $filePath;
		$fileContent = '' unless defined $fileContent;

		my $rs = $self->{'eventManager'}->trigger('beforeHttpdDelHtaccess', \$fileContent, $data);
		return $rs if $rs;

		my $bTag = "### START i-MSCP PROTECTION ###\n";
		my $eTag = "### END i-MSCP PROTECTION ###\n";

		$fileContent = replaceBloc($bTag, $eTag, '', $fileContent);

		$rs = $self->{'eventManager'}->trigger('afterHttpdDelHtaccess', \$fileContent, $data);
		return $rs if $rs;

		if($fileContent ne '') {
			$rs = $file->set($fileContent);
			return $rs if $rs;

			$rs = $file->save();
			return $rs if $rs;

			$rs = $file->mode(0640);
			return $rs if $rs;

			$rs = $file->owner($data->{'USER'}, $data->{'GROUP'});
			return $rs if $rs;
		} else {
			$rs = $file->delFile() if -f $filePath;
			return $rs if $rs;
		}
	}

	0;
}

=item addIps(\%data)

 Process addIps tasks

 Param hash \%data Ips data
 Return int 0 on success, other on failure

=cut

sub addIps
{
	my ($self, $data) = @_;

	my $version = $self->{'config'}->{'HTTPD_VERSION'};

	unless(version->parse($version) >= version->parse('2.4.0')) {
		my $file = "$self->{'apacheWrkDir'}/00_nameserver.conf";

		if(-f $file) {
			my $rs = iMSCP::File->new(
				filename => $file
			)->copyFile(
				"$self->{'apacheBkpDir'}/00_nameserver.conf." . time
			);
			return $rs if $rs;
		}

		$file = iMSCP::File->new( filename => $file );
		my $fileContent = $file->get();
		unless(defined $fileContent) {
			error("Unable to read $file->{'filename'} file");
			return 1;
		}

		my $rs = $self->{'eventManager'}->trigger('beforeHttpdAddIps', \$fileContent, $data);
		return $rs if $rs;

		my $ipMngr = iMSCP::Net->getInstance();
		my $confSnippet = "\n";

		for my $ipAddr(@{$data->{'SSL_IPS'}}) {
			if($ipMngr->getAddrVersion($ipAddr) eq 'ipv4') {
				$confSnippet .= "NameVirtualHost $ipAddr:443\n";
			} else {
				$confSnippet .= "NameVirtualHost [$ipAddr]:443\n";
			}
		}

		for my $ipAddr(@{$data->{'IPS'}}) {
			if($ipMngr->getAddrVersion($ipAddr) eq 'ipv4') {
				$confSnippet .= "NameVirtualHost $ipAddr:80\n";
			} else {
				$confSnippet .= "NameVirtualHost [$ipAddr]:80\n";
			}
		}

		$fileContent .= $confSnippet;

		$rs = $self->{'eventManager'}->trigger('afterHttpdAddIps', \$fileContent, $data);
		return $rs if $rs;

		$rs = $file->set($fileContent);
		return $rs if $rs;

		$rs = $file->save();
		return $rs if $rs;

		$rs = $self->installConfFile('00_nameserver.conf');
		return $rs if $rs;

		$rs = $self->enableSites('00_nameserver.conf');
		return $rs if $rs;

		$self->{'restart'} = 1;
	}

	0;
}

=item buildConf($cfgTpl, $filename [, \%data ])

 Build the given configuration template

 Param string $cfgTpl Template content
 Param string $filename Template filename
 Param hash \%data OPTIONAL Data as provided by Alias|Domain|Subdomain|SubAlias modules or installer
 Return string Template content

=cut

sub buildConf
{
	my ($self, $cfgTpl, $filename, $data) = @_;

	$self->{'eventManager'}->trigger('beforeHttpdBuildConf', \$cfgTpl, $filename, $data);

	$cfgTpl = process($self->{'data'}, $cfgTpl);

	$self->{'eventManager'}->trigger('afterHttpdBuildConf', \$cfgTpl, $filename, $data);

	$cfgTpl;
}

=item buildConfFile($file [, \%data = { } [, \%options = { } ]])

 Build the given configuration file.

 Param string $file Absolute path to config file or config filename relative to the i-MSCP apache config directory
 Param hash \%data OPTIONAL Data as provided by Alias|Domain|Subdomain|SubAlias modules or installer
 Param hash \%options OPTIONAL Options such as destination, mode, user and group for final file
 Return int 0 on success, other on failure

=cut

sub buildConfFile
{
	my ($self, $file, $data, $options) = @_;

	$data ||= { };
	$options ||= { };

	my ($filename, $path) = fileparse($file);

	# Load template

	my $cfgTpl;
	my $rs = $self->{'eventManager'}->trigger('onLoadTemplate', 'apache_itk', $filename, \$cfgTpl, $data);
	return $rs if $rs;

	unless(defined $cfgTpl) {
		$file = "$self->{'apacheCfgDir'}/$file" unless -d $path && $path ne './';

		$cfgTpl = iMSCP::File->new( filename => $file )->get();
		unless(defined $cfgTpl) {
			error("Unable to read $file");
			return 1;
		}
	}

	# Build file

	$rs = $self->{'eventManager'}->trigger('beforeHttpdBuildConfFile', \$cfgTpl, $filename, $data, $options);
	return $rs if $rs;

	$cfgTpl = $self->buildConf($cfgTpl, $filename, $data);
	return 1 unless defined $cfgTpl;

	$rs = $self->{'eventManager'}->trigger('afterHttpdBuildConfFile', \$cfgTpl, $filename, $data, $options);
	return $rs if $rs;

	# Store file

	my $fileHandler = iMSCP::File->new(
		filename => ($options->{'destination'}) ? $options->{'destination'} : "$self->{'apacheWrkDir'}/$filename"
	);

	$rs = $fileHandler->set($cfgTpl);
	return $rs if $rs;

	$rs = $fileHandler->save();
	return $rs if $rs;

	$rs = $fileHandler->mode($options->{'mode'} ? $options->{'mode'} : 0644);
	return $rs if $rs;

	$fileHandler->owner(
		$options->{'user'} ? $options->{'user'} : $main::imscpConfig{'ROOT_USER'},
		$options->{'group'} ? $options->{'group'} : $main::imscpConfig{'ROOT_GROUP'}
	);
}

=item installConfFile($file [, \%options = { } ])

 Install the given configuration file

 Param string $file Absolute path to config file or config filename relative to the i-MSCP apache working directory
 Param hash \%options OPTIONAL Options such as destination, mode, user and group for final file
 Return int 0 on success, other on failure

=cut

sub installConfFile
{
	my ($self, $file, $options) = @_;

	$options ||= { };

	my ($filename, $path) = fileparse($file);

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdInstallConfFile', $filename, $options);
	return $rs if $rs;

	$file = "$self->{'apacheWrkDir'}/$file" unless -d $path && $path ne './';

	my $fileHandler = iMSCP::File->new( filename => $file );

	$rs = $fileHandler->mode($options->{'mode'} ? $options->{'mode'} : 0644);
	return $rs if $rs;

	$rs = $fileHandler->owner(
		$options->{'user'} ? $options->{'user'} : $main::imscpConfig{'ROOT_USER'},
		$options->{'group'} ? $options->{'group'} : $main::imscpConfig{'ROOT_GROUP'}
	);
	return $rs if $rs;

	$rs = $fileHandler->copyFile(
		($options->{'destination'}) ?
			$options->{'destination'} : "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$filename"
	);
	return $rs if $rs;

	$self->{'eventManager'}->trigger('afterHttpdInstallConfFile', $filename, $options);
}

=item setData(\%data)

 Make the given data available for this server

 Param hash \%data Server data
 Return int 0 on success, other on failure

=cut

sub setData
{
	my ($self, $data) = @_;

	@{$self->{'data'}}{keys %{$data}} = values %{$data};

	0;
}

=item flushData()

 Flush all data set via the setData() method

 Return int 0

=cut

sub flushData
{
	my $self = shift;

	delete $self->{'data'};

	0;
}

=item getTraffic($timestamp)

 Get httpd traffic data

 Return hash Traffic data or die on failure

=cut

sub getTraffic
{
	my $self = shift;

	my $timestamp = time();
	my $trafficDbPath = "$main::imscpConfig{'VARIABLE_DATA_DIR'}/http_traffic.db";

	# Load traffic database (create it if doesn't exist)
	tie my %trafficDb, 'iMSCP::Config', fileName => $trafficDbPath, nowarn => 1;

	require Date::Format;
	Date::Format->import();
	my $ldate = time2str('%Y%m%d', $timestamp);

	my $db = iMSCP::Database->factory();
	my $dbh = $db->startTransaction();

	eval {
		# Collect traffic data
		my $sth = $dbh->prepare('SELECT vhost, bytes FROM httpd_vlogger WHERE ldate <= ? FOR UPDATE');
		$sth->execute($ldate);

		while (my $row = $sth->fetchrow_hashref()) {
			$trafficDb{$row->{'vhost'}} += $row->{'bytes'}
		}

		# Delete traffic data source
		$dbh->do('DELETE FROM httpd_vlogger WHERE ldate <= ?', undef, $ldate);

		$dbh->commit();
	};

	if($@) {
		$dbh->rollback();
		%trafficDb = ();
		$db->endTransaction();
		die("Unable to collect traffic data: $@");
	}

	$db->endTransaction();

	# Schedule deletion of full traffic database. This is only done on success. On failure, the traffic database is kept
	# in place for later processing. In such case, data already processed are zeroed by the traffic processor script.
	$self->{'eventManager'}->register(
		'afterVrlTraffic', sub { (-f $trafficDbPath) ? iMSCP::File->new( filename => $trafficDbPath )->delFile() : 0; }
	);

	\%trafficDb;
}

=item getRunningUser()

 Get user name under which the Apache server is running

 Return string User name under which the apache server is running

=cut

sub getRunningUser
{
	my $self = shift;

	$self->{'config'}->{'HTTPD_USER'};
}

=item getRunningGroup()

 Get group name under which the Apache server is running

 Return string Group name under which the apache server is running

=cut

sub getRunningGroup
{
	my $self = shift;

	$self->{'config'}->{'HTTPD_GROUP'};
}

=item enableSites($sites)

 Enable the given sites

 Param string $sites Names of sites to enable, each space separated
 Return int 0 on sucess, other on failure

=cut

sub enableSites
{
	my ($self, $sites) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdEnableSites', \$sites);
	return $rs if $rs;

	for my $site(split(' ', $sites)){
		if(-f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$site") {
			my ($stdout, $stderr);
			my $rs = execute("a2ensite $site", \$stdout, \$stderr);
			debug($stdout) if $stdout;
			error($stderr) if $stderr && $rs;
			return $rs if $rs;

			$self->{'restart'} = 1;
		} else {
			warning("Site $site doesn't exist");
		}
	}

	$self->{'eventManager'}->trigger('afterHttpdEnableSites', $sites);
}

=item disableSites($sites)

 Disable the given sites

 Param string $sites Names of sites to disable, each space separated
 Return int 0 on sucess, other on failure

=cut

sub disableSites
{
	my ($self, $sites) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdDisableSites', \$sites);
	return $rs if $rs;

	for my $site(split(' ', $sites)) {
		if(-f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$site") {
			my ($stdout, $stderr);
			my $rs = execute("a2dissite $site", \$stdout, \$stderr);
			debug($stdout) if $stdout;
			error($stderr) if $stderr && $rs;
			return $rs if $rs;

			$self->{'restart'} = 1;
		} else {
			warning("Site $site doesn't exist");
		}
	}

	$self->{'eventManager'}->trigger('afterHttpdDisableSites', $sites);
}

=item enableModules($modules)

 Enable the given Apache modules

 Param string $modules Names of Apache modules to enable, each space separated
 Return int 0 on sucess, other on failure

=cut

sub enableModules
{
	my ($self, $modules) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdEnableModules', \$modules);
	return $rs if $rs;

	my ($stdout, $stderr);
	$rs = execute("a2enmod $modules", \$stdout, \$stderr);
	debug($stdout) if $stdout;
	error($stderr) if $stderr && $rs;
	return $rs if $rs;

	$self->{'restart'} = 1;

	$self->{'eventManager'}->trigger('afterHttpdEnableModules', $modules);
}

=item disableModules($modules)

 Disable the given Apache modules

 Param string $modules Names of Apache modules to disable, each space separated
 Return int 0 on sucess, other on failure

=cut

sub disableModules
{
	my ($self, $modules) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdDisableModules', \$modules);
	return $rs if $rs;

	my ($stdout, $stderr);
	$rs = execute("a2dismod $modules", \$stdout, \$stderr);
	debug($stdout) if $stdout;
	error($stderr) if $stderr && $rs;
	return $rs if $rs;

	$self->{'restart'} = 1;

	$self->{'eventManager'}->trigger('afterHttpdDisableModules', $modules);
}

=item enableConfs($conffiles)

 Enable the given configuration files

 Param string $conffiles Names of configuration files to enable, each space separated
 Return int 0 on sucess, other on failure

=cut

sub enableConfs
{
	my ($self, $conffiles) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdEnableConfs', \$conffiles);
	return $rs if $rs;

	if(iMSCP::ProgramFinder::find('a2enconf')) {
		if(-d "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available") {
			for my $conffile(split(' ', $conffiles)) {
				if(-f "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available/$conffile") {
					my ($stdout, $stderr);
					my $rs = execute("a2enconf $conffile", \$stdout, \$stderr);
					debug($stdout) if $stdout;
					error($stderr) if $stderr && $rs;
					return $rs if $rs;

					$self->{'restart'} = 1;
				} else {
					warning("Configuration file $conffile doesn't exist");
				}
			}
		}
	}

	$self->{'eventManager'}->trigger('afterHttpdEnableConfs', $conffiles);
}

=item disableConfs($conffiles)

 Disable the given configuration files

 Param string $conffiles Names of configuration files to disable, each space separated
 Return int 0 on sucess, other on failure

=cut

sub disableConfs
{
	my ($self, $conffiles) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdDisableConfs', \$conffiles);
	return $rs if $rs;

	if(iMSCP::ProgramFinder::find('a2disconf')) {
		if(-d "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available") {
			for my $conffile(split(' ', $conffiles)) {
				if(-f "$self->{'config'}->{'HTTPD_CONF_DIR'}/conf-available/$conffile") {
					my ($stdout, $stderr);
					my $rs = execute("a2disconf $conffile", \$stdout, \$stderr);
					debug($stdout) if $stdout;
					error($stderr) if $stderr && $rs;
					return $rs if $rs;

					$self->{'restart'} = 1;
				} else {
					warning("Configuration file $conffile doesn't exist");
				}
			}
		}
	}

	$self->{'eventManager'}->trigger('afterHttpdDisableConfs', $conffiles);
}

=item forceRestartApache()

 Force Apache to be restarted

 Return int 0

=cut

sub forceRestart
{
	my $self = shift;

	$self->{'forceRestart'} = 1;

	0;
}

=item startApache()

 Start httpd service

 Return int 0 on success, other on failure

=cut

sub start
{
	my $self = shift;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdStart');
	return $rs if $rs;

	iMSCP::Service->getInstance()->start($self->{'config'}->{'HTTPD_SNAME'});

	$self->{'eventManager'}->trigger('afterHttpdStart');
}

=item stopApache()

 Stop httpd service

 Return int 0 on success, other on failure

=cut

sub stop
{
	my $self = shift;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdStop');
	return $rs if $rs;

	iMSCP::Service->getInstance()->stop($self->{'config'}->{'HTTPD_SNAME'});

	$self->{'eventManager'}->trigger('afterHttpdStop');
}

=item restartApache()

 Restart or reload httpd service

 Return int 0 on success, other on failure

=cut

sub restart
{
	my $self = shift;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdRestart');
	return $rs if $rs;

	if($self->{'forceRestart'}) {
		iMSCP::Service->getInstance()->restart($self->{'config'}->{'HTTPD_SNAME'});
	} else {
		iMSCP::Service->getInstance()->reload($self->{'config'}->{'HTTPD_SNAME'});
	}

	$self->{'eventManager'}->trigger('afterHttpdRestart');
}

=back

=head1 PRIVATE METHODS

=over 4

=item _init()

 Initialize instance

 Return Servers::httpd::apache_itk

=cut

sub _init
{
	my $self = shift;

	$self->{'start'} = 0;
	$self->{'restart'} = 0;

	$self->{'eventManager'} = iMSCP::EventManager->getInstance();

	$self->{'eventManager'}->trigger(
		'beforeHttpdInit', $self, 'apache_itk'
	) and fatal('apache_itk - beforeHttpdInit has failed');

	$self->{'apacheCfgDir'} = "$main::imscpConfig{'CONF_DIR'}/apache";
	$self->{'apacheBkpDir'} = "$self->{'apacheCfgDir'}/backup";
	$self->{'apacheWrkDir'} = "$self->{'apacheCfgDir'}/working";
	$self->{'apacheTplDir'} = "$self->{'apacheCfgDir'}/parts";

	$self->{'config'} = lazy { tie my %c, 'iMSCP::Config', fileName => "$self->{'apacheCfgDir'}/apache.data"; \%c; };

	$self->{'eventManager'}->trigger(
		'afterHttpdInit', $self, 'apache_itk'
	) and fatal('apache_itk - afterHttpdInit has failed');

	# Register event listener which is responsible to clean vhost template files
	$self->{'eventManager'}->register('afterHttpdBuildConfFile', sub { $self->_cleanTemplate(@_)});

	$self;
}

=item _addCfg(\%data)

 Add configuration files for the given domain

 Param hash \%data Data as provided by Alias|Domain|Subdomain|SubAlias modules
 Return int 0 on success, other on failure

=cut

sub _addCfg
{
	my ($self, $data) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdAddCfg', $data);
	return $rs if $rs;

	# Set needed data

	$self->setData($data);
	$self->setData(
		{
			TMPDIR => $data->{'HOME_DIR'} . '/phptmp',
			EMAIL_DOMAIN => $data->{'DOMAIN_NAME'}
		}
	);

	# Disable Apache2 domain vhost files
	for my $conffile("$data->{'DOMAIN_NAME'}.conf", "$data->{'DOMAIN_NAME'}_ssl.conf") {
		if(-f "$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$conffile") {
			$rs = $self->disableSites($_);
			return $rs if $rs;
		}
	}

	# Remove previous Apache2 domain vhost files
	for my $conffile(
		"$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}.conf",
		"$self->{'config'}->{'HTTPD_SITES_AVAILABLE_DIR'}/$data->{'DOMAIN_NAME'}_ssl.conf",
		"$self->{'apacheWrkDir'}/$data->{'DOMAIN_NAME'}.conf",
		"$self->{'apacheWrkDir'}/$data->{'DOMAIN_NAME'}_ssl.conf"
	) {
		if(-f $conffile) {
			$rs = iMSCP::File->new( filename => $conffile )->delFile();
			return $rs if $rs;
		}
	}

	# Build Apache sites - Begin

	my @templates = (
		{
			tplFile => ($data->{'FORWARD'} eq 'no') ? 'domain.tpl' : 'domain_redirect.tpl',
			siteFile => "$data->{'DOMAIN_NAME'}.conf"
		}
	);

	if($data->{'SSL_SUPPORT'}) {
		push @templates, {
			tplFile => ($data->{'FORWARD'} eq 'no') ? 'domain_ssl.tpl' : 'domain_redirect_ssl.tpl',
			siteFile => "$data->{'DOMAIN_NAME'}_ssl.conf"
		};

		$self->setData({ CERTIFICATE => "$main::imscpConfig{'GUI_ROOT_DIR'}/data/certs/$data->{'DOMAIN_NAME'}.pem" });
	}

	my $version = $self->{'config'}->{'HTTPD_VERSION'};
	my $apache24 = (version->parse($version) >= version->parse('2.4.0'));

	my $ipMngr = iMSCP::Net->getInstance();

	$self->setData(
		{
			BASE_SERVER_VHOST => $main::imscpConfig{'BASE_SERVER_VHOST'},
			HTTPD_LOG_DIR => $self->{'config'}->{'HTTPD_LOG_DIR'},
			HTTPD_CUSTOM_SITES_DIR => $self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'},
			AUTHZ_ALLOW_ALL => ($apache24) ? 'Require all granted' : 'Allow from all',
			AUTHZ_DENY_ALL => ($apache24) ? 'Require all denied' : 'Deny from all',
			DOMAIN_IP => ($ipMngr->getAddrVersion($data->{'DOMAIN_IP'}) eq 'ipv4')
				? $data->{'DOMAIN_IP'} : "[$data->{'DOMAIN_IP'}]"
		}
	);

	for my $template(@templates) {
		$rs = $self->buildConfFile(
			"$self->{'apacheTplDir'}/$template->{'tplFile'}",
			$data,
			{ destination => "$self->{'apacheWrkDir'}/$template->{'siteFile'}" }
		);

		$rs = $self->installConfFile($template->{'siteFile'});
		return $rs if $rs;
	}

	# Build Apache sites - End

	# Build and install custom Apache configuration file
	unless (-f "$self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/$data->{'DOMAIN_NAME'}.conf") {
		$rs = $self->buildConfFile(
			"$self->{'apacheTplDir'}/custom.conf.tpl",
			$data,
			{ destination => "$self->{'config'}->{'HTTPD_CUSTOM_SITES_DIR'}/$data->{'DOMAIN_NAME'}.conf" }
		);
		return $rs if $rs;
	}

	# Enable Apache sites
	for my $template(@templates) {
		$rs = $self->enableSites($template->{'siteFile'});
		return $rs if $rs;
	}

	$self->{'eventManager'}->trigger('afterHttpdAddCfg');
}

=item _dmnFolders(\%data)

 Get Web folders list to create for the given domain

 Param hash \%data Data as provided by Alias|Domain|Subdomain|SubAlias modules
 Return array List of Web folders to create

=cut

sub _dmnFolders
{
	my ($self, $data) = @_;

	my @folders = ();

	$self->{'eventManager'}->trigger('beforeHttpdDmnFolders', \@folders);

	push(@folders, [
		"$self->{'config'}->{'HTTPD_LOG_DIR'}/$data->{'DOMAIN_NAME'}",
		$main::imscpConfig{'ROOT_USER'},
		$main::imscpConfig{'ROOT_GROUP'},
		0750
	]);

	$self->{'eventManager'}->trigger('afterHttpdDmnFolders', \@folders);

	@folders;
}

=item _addFiles(\%data)

 Add default directories and files for the given domain

 Param hash \%data Data as provided by Alias|Domain|Subdomain|SubAlias modules
 Return int 0 on sucess, other on failure

=cut

sub _addFiles
{
	my ($self, $data) = @_;

	my $rs = $self->{'eventManager'}->trigger('beforeHttpdAddFiles', $data);
	return $rs if $rs;

	# Create directories as returned by the dmnFolders() method
	for my $folderDef($self->_dmnFolders($data)) {
		$rs = iMSCP::Dir->new( dirname => $folderDef->[0] )->make(
			{ user => $folderDef->[1], group => $folderDef->[2], mode => $folderDef->[3] }
		);
		return $rs if $rs;
	}

	# Create Web folder tree only if th domain is not forwarded
	if($data->{'FORWARD'} eq 'no') {
		# Build Web directory tree using skeleton from /etc/imscp/apache/skel - BEGIN

		my $webDir = $data->{'WEB_DIR'};
		my $skelDir;

		if($data->{'DOMAIN_TYPE'} eq 'dmn') {
			$skelDir = "$main::imscpConfig{'CONF_DIR'}/skel/domain";
		} elsif($data->{'DOMAIN_TYPE'} eq 'als') {
			$skelDir = "$main::imscpConfig{'CONF_DIR'}/skel/alias";
		} else {
			$skelDir = "$main::imscpConfig{'CONF_DIR'}/skel/subdomain";
		}

		my ($tmpDir, $stdout, $stderr);

		if(-d $skelDir) {
			$tmpDir = File::Temp->newdir();

			$rs = execute("cp -RT $skelDir $tmpDir", \$stdout, \$stderr);
			debug($stdout) if $stdout;
			error($stderr) if $stderr && $rs;
			return $rs if $rs;
		} else {
			error("Skeleton directory $skelDir doesn't exist.");
			return 1;
		}

		# Build default page if needed ( if htdocs doesn't exist or is empty )
		if(! -d "$webDir/htdocs" || iMSCP::Dir->new( dirname => "$webDir/htdocs" )->isEmpty()) {
			if(-d "$tmpDir/htdocs") {
				# Test needed in case admin removed the index.html file from the skeleton
				if(-f "$tmpDir/htdocs/index.html") {
					my $fileSource = "$tmpDir/htdocs/index.html";
					$rs = $self->buildConfFile($fileSource, $data, { destination => $fileSource });
					return $rs if $rs;
				}
			} else {
				error("Web folder skeleton $skelDir must provide the 'htdocs' directory.");
				return 1;
			}
		} else {
			$rs = iMSCP::Dir->new( dirname => "$tmpDir/htdocs" )->remove();
			return $rs if $rs;
		}

		if(
			$data->{'DOMAIN_TYPE'} eq 'dmn' && -d "$webDir/errors" &&
			! iMSCP::Dir->new( dirname => "$webDir/errors" )->isEmpty()
		) {
			if(-d "$tmpDir/errors") {
				$rs = iMSCP::Dir->new( dirname => "$tmpDir/errors" )->remove();
				return $rs if $rs;
			} else {
				warning("Web folder skeleton $skelDir should provide the 'errors' directory.");
			}
		}

		# Build Web directory tree using skeleton /etc/imscp/apache/skel - END

		my $parentDir = dirname($webDir);

		# Fix #1327 - Ensure that parent Web folder exists
		unless(-d $parentDir) {
			clearImmutable(dirname($parentDir));

			# Create parent Web folder
			$rs = iMSCP::Dir->new( dirname => $parentDir )->make(
				{ user => $data->{'USER'}, group => $data->{'GROUP'}, mode => 0750 }
			);
			return $rs if $rs;
		} else {
			clearImmutable($parentDir);
		}

		if(-d $webDir) {
			clearImmutable($webDir);
		} else {
			# Create Web folder
			$rs = iMSCP::Dir->new( dirname => $webDir )->make(
				{ user => $data->{'USER'}, group => $data->{'GROUP'}, mode => 0750 }
			);
			return $rs if $rs;
		}

		# Copy Web directory tree to the Web directory
		$rs = execute("cp -nRT $tmpDir $webDir", \$stdout, \$stderr);
		debug($stdout) if $stdout;
		error($stderr) if $stderr && $rs;
		return $rs if $rs;

		# Permissions, owner and group - Begin

		# Sets permissions for root of Web folder
		$rs = setRights($webDir, { user => $data->{'USER'}, group => $data->{'GROUP'}, mode => '0750' });
		return $rs if $rs;

		# Get list of directories/files for which permissions, owner and group must be set
		my @files = iMSCP::Dir->new( dirname => $skelDir )->getAll();

		# Set default owner and group recursively
		for my $file(@files) {
			if(-e "$webDir/$file") {
				$rs = setRights( "$webDir/$file", { user => $data->{'USER'}, group => $data->{'GROUP'}, recursive => 1 } );
				return $rs if $rs;
			}
		}

		# Sets default permissions recursively, excepted for directories for which permissions of directories and files
		# they contain should be preserved
		for my $file(@files) {
			if(-d "$webDir/$file") {
				$rs = setRights("$webDir/$file", {
					dirmode => '0750',
					filemode => '0640',
					recursive => ($file ~~ [ '00_private', 'cgi-bin', 'htdocs' ]) ? 0 : 1
				});
				return $rs if $rs;
			}
		}

		# Sets owner and group for files that should be hidden to user
		for my $file('domain_disable_page', '.htgroup', '.htpasswd') {
			if(-e "$webDir/$file") {
				$rs = setRights("$webDir/$file", {
					user => $main::imscpConfig{'ROOT_USER'},
					group => $self->getRunningGroup(),
					recursive => 1
				});
				return $rs if $rs;
			}
		}

		# Removed deprecated phptmp directory if any
		if($data->{'DOMAIN_TYPE'} ne 'dmn' && ! $data->{'SHARED_MOUNT_POINT'}) {
			$rs = iMSCP::Dir->new( dirname => "$webDir/phptmp")->remove();
			return $rs if $rs;
		}

		if($data->{'WEB_FOLDER_PROTECTION'} eq 'yes') {
			(my $userWebDir = $main::imscpConfig{'USER_WEB_DIR'}) =~ s%/+$%%;
			do {
				setImmutable($webDir);
			} while (($webDir = dirname($webDir)) ne $userWebDir);
		}

		# Permissions, owner and group - Ending
	}

	$self->{'eventManager'}->trigger('afterHttpdAddFiles', $data);
}

=item _cleanTemplate(\$cfgTpl, $filename, \%data)

 Event listener which is responsible to remove useless configuration snippets in vhost template files

 Param string \$cfgTpl Template content
 Param string $filename Template filename
 Param hash \%data Data as provided by Alias|Domain|Subdomain|SubAlias modules
 Return int 0

=cut

sub _cleanTemplate
{
	my ($self, $cfgTpl, $filename, $data) = @_;

	if($filename =~ /^domain(?:_ssl)?\.tpl$/) {
		$$cfgTpl = replaceBloc("# SECTION suexec BEGIN.\n", "# SECTION suexec END.\n", '', $$cfgTpl);

		unless($data->{'CGI_SUPPORT'} eq 'yes') {
			$$cfgTpl = replaceBloc("# SECTION cgi_support BEGIN.\n", "# SECTION cgi_support END.\n", '', $$cfgTpl);
		}

		if($data->{'PHP_SUPPORT'} eq 'yes') {
			$$cfgTpl = replaceBloc("# SECTION php_disabled BEGIN.\n", "# SECTION php_disabled END.\n", '', $$cfgTpl);
		} else {
			$$cfgTpl = replaceBloc("# SECTION php_enabled BEGIN.\n", "# SECTION php_enabled END.\n", '', $$cfgTpl);
		}

		$$cfgTpl = replaceBloc("# SECTION fcgid BEGIN.\n", "# SECTION fcgid END.\n", '', $$cfgTpl);
		$$cfgTpl = replaceBloc("# SECTION php_fpm BEGIN.\n", "# SECTION php_fpm END.\n", '', $$cfgTpl);
	}

	# Remove tags
	$$cfgTpl =~ s/^[ \t]+#.*?(?:BEGIN|END)\.\n//gmi;
	$$cfgTpl =~ s/\n{3}/\n\n/g;

	0;
}

=back

=head1 AUTHORS

 Daniel Andreca <sci2tech@gmail.com>
 Laurent Declercq <l.declercq@nuxwin.com>

=cut

1;
__END__
