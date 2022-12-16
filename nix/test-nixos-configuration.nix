{ config, modulesPath, pkgs, cardano-configurations, ... }:
{
  imports = [ "${modulesPath}/virtualisation/qemu-vm.nix" ];

  virtualisation = {
    memorySize = 8192;
    diskSize = 100000;
    forwardPorts = [
      { from = "host"; host.port = 2222; guest.port = 22; }
      { from = "host"; host.port = 1337; guest.port = 1337; }
    ];
  };

  # WARNING: root access with empty password for debugging via console and ssh
  networking.firewall.enable = false;
  services.getty.autologinUser = "root";
  services.openssh.enable = true;
  services.openssh.permitRootLogin = "yes";
  users.extraUsers.root.password = "";
  users.mutableUsers = false;

  # services

  services.cardano-node = {
    enable = true;
    systemdSocketActivation = true;
    nodeConfigFile = "${cardano-configurations}/network/mainnet/cardano-node/config.json";
    topology = "${cardano-configurations}/network/mainnet/cardano-node/topology.json";
  };

  services.ogmios = {
    enable = true;
    host = "0.0.0.0";
    nodeSocket = "/var/run/cardano-node/node.socket";
  };
}
