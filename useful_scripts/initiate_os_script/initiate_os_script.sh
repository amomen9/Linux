#!/usr/bin/env bash
# This script is used to initiate the OS script for setting up the environment.

apt update && apt upgrade -y

printf "\nExecuting the following scripts in order:\n\n"
printf "\n    1. install_packages/Install_Server_with_Minimum_UI/install_server_with_minimum_ui.sh\n\n"
printf "\n    2. install_packages/Install_and_Setup_TigerVNC_Server/setup-vnc-combined.sh\n\n"
printf "\n    3. install_packages/Install_Docker_Engine/install_docker_engine.sh\n\n"
printf "\n    4. maintenance/Scheduled_systemd_Automatic_Update/install_system_maintenance.sh\n\n"
printf "\n    5. useful_scripts/bandwidth_test/bandwidth_test.sh\n\n"
printf "\n--------------------------------------------------------------------------------\n1.\n"


chmod +x ../../../{\
install_packages/Install_Server_with_Minimum_UI/install_server_with_minimum_ui.sh,\
install_packages/Install_and_Setup_TigerVNC_Server/setup-vnc-combined.sh,\
maintenance/Scheduled_systemd_Automatic_Update/install_system_maintenance.sh,\
useful_scripts/bandwidth_test/bandwidth_test.sh}

../../../{\
install_packages/Install_Server_with_Minimum_UI/install_server_with_minimum_ui.sh --minimal --desktop xfce\
,printf "\n--------------------------------------------------------------------------------\n2.\n"\
,install_packages/Install_and_Setup_TigerVNC_Server/setup-vnc-combined.sh\
,printf "\n--------------------------------------------------------------------------------\n3.\n"\
,maintenance/Scheduled_systemd_Automatic_Update/install_system_maintenance.sh  --update --restart\
,printf "\n--------------------------------------------------------------------------------\n4.\n"\
,useful_scripts/bandwidth_test/bandwidth_test.sh --mbps}