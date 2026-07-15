## Basic Commands

```sh
# Set variable in current session
TEST_VAR=test
echo $TEST_VAR

# For a variable to be available to child process
export TEST_VAR1=export_variable

# To persist variable through sessions write to ~/.bashrc or ~/.bash_profile or preferred shell
echo 'export TEST=test' >> ~/.bashrc
source ~/.bashrc # Use variable in current session without exiting

# check PATH - colon separated directories list where shell searched for commands
echo $PATH

# Add directory to PATH
export PATH="$HOME/.local/bin:$PATH"

which grep
/usr/bin/grep

# Navigation

ls
ls -la # Include hidden files
ls -R # Recursive listing
tree
tree -d # Directories only
tree -a # Include hidden files

# LVM and Disks

lsblk # List block devices in tree format
sudo fdisk -l # Low level physical partition tables for all connected drives
df -h # Mounted filesystems, total capacity, current disk usage

sudo pvs # High level summary of physical volumes
sudo pvdisplay # Detailed attributes
sudo pvscan # Scan all disks for existing physical volumes

sudo vgs # Summary of volume groups, free space and assigned PV's
sudo vgdisplay # Detailed attributes of volume groups
sudo vgscan # Scan all volume groups

sudo lvs # Summary of logical volumes
sudo lvdisplay # Detailed attributes of logical volumes
sudo lvscan # Scan all logical volumes


# TO DO
# - File Operations
# - Check networks
# - Process Management@


```