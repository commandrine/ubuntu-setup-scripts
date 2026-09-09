# Update ClamAV signatures

sudo freshclam

 

# Update Maldet

sudo maldet --update-ver

sudo maldet --update-sigs

 

# Scan home directory

sudo maldet --scan-all /home

 

# Review findings manually

sudo maldet --report list