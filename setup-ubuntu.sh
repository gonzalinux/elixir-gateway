#!/bin/bash

# ElixirGateway - Ubuntu Setup Script
# This script installs all dependencies needed to run the ElixirGateway project on Ubuntu

set -e  # Exit on error

echo "======================================"
echo "ElixirGateway - Ubuntu Setup"
echo "======================================"
echo ""

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_info() {
    echo -e "${YELLOW}[i]${NC} $1"
}

# Check if running on Ubuntu
if [ ! -f /etc/os-release ] || ! grep -q "ubuntu" /etc/os-release; then
    echo "Warning: This script is designed for Ubuntu. It may not work on other distributions."
    read -p "Continue anyway? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 1
    fi
fi

# Update package list
print_info "Updating package list..."
sudo apt-get update

# Install essential build tools
print_info "Installing build essentials and dependencies..."
sudo apt-get install -y \
    build-essential \
    git \
    curl \
    wget \
    unzip \
    tmux \
    libssl-dev \
    libncurses5-dev \
    automake \
    autoconf \
    ca-certificates

print_status "Build tools installed"

# Install Erlang
print_info "Installing Erlang/OTP..."
# Add Erlang Solutions repository
wget https://packages.erlang-solutions.com/erlang-solutions_2.0_all.deb
sudo dpkg -i erlang-solutions_2.0_all.deb
rm erlang-solutions_2.0_all.deb
sudo apt-get update

# Install Elixir
print_info "Installing Elixir..."
curl -fsSO https://elixir-lang.org/install.sh
sh install.sh elixir@1.19.4 otp@28.1
installs_dir=$HOME/.elixir-install/installs
export PATH=$installs_dir/otp/28.1/bin:$PATH
export PATH=$installs_dir/elixir/1.19.4-otp-28/bin:$PATH

# Add Elixir paths to .bashrc for persistence
print_info "Adding Elixir paths to .bashrc..."
if ! grep -q ".elixir-install/installs" ~/.bashrc; then
    echo "" >> ~/.bashrc
    echo "# Elixir installation paths" >> ~/.bashrc
    echo "export PATH=\$HOME/.elixir-install/installs/otp/28.1/bin:\$PATH" >> ~/.bashrc
    echo "export PATH=\$HOME/.elixir-install/installs/elixir/1.19.4-otp-28/bin:\$PATH" >> ~/.bashrc
    print_status "Elixir paths added to .bashrc"
else
    print_status "Elixir paths already in .bashrc"
fi

print_status "Elixir installed"

# Verify installations
echo ""
echo "======================================"
echo "Verifying installations:"
echo "======================================"
elixir --version
echo ""

# Install Hex package manager
print_info "Installing Hex package manager..."
mix local.hex --force

print_status "Hex installed"

# Install Phoenix
print_info "Installing Phoenix archive..."
mix archive.install hex phx_new --force

print_status "Phoenix archive installed"

# Install Rebar (build tool for Erlang dependencies)
print_info "Installing Rebar..."
mix local.rebar --force

print_status "Rebar installed"

# Optional: Install snapd and certbot for SSL
echo ""
read -p "Do you want to install certbot for SSL certificate management? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_info "Installing snapd..."
    sudo apt-get install -y snapd

    print_info "Installing certbot..."
    sudo snap install --classic certbot
    sudo ln -sf /snap/bin/certbot /usr/bin/certbot || true

    print_status "Certbot installed"
fi

# Setup project dependencies
echo ""
read -p "Do you want to install project dependencies now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    print_info "Installing project dependencies..."
    cd "$(dirname "$0")"
    mix deps.get
    print_status "Project dependencies installed"
fi

echo ""
echo "======================================"
echo "Setup Complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "  1. Configure your gateway services in config/dev.exs or config/runtime.exs"
echo "  2. Run 'make setup' or 'mix deps.get' to ensure all dependencies are installed"
echo "  3. Run 'make run' or 'mix phx.server' to start the server"
echo ""
echo "For production deployment:"
echo "  1. Set SECRET_KEY_BASE environment variable (generate with: mix phx.gen.secret)"
echo "  2. Configure your gateway service mappings"
echo "  3. Set up SSL certificates using certbot or SiteEncrypt"
echo ""
print_status "All done! Happy coding!"
