#!/bin/bash

PROGNAME=$(basename $0)
SUBCOMMAND=$1
LESSON_DIRECTORY="../nrelabs-curriculum"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
WHITE='\033[37m'
NC='\033[0m'

# Checking for prerequisites
command -v minikube > /dev/null
if [ $? -ne 0 ]; then
    echo "Minikube not found. Please follow installation instructions at: https://antidoteproject.readthedocs.io/en/latest/building/buildlocal.html"
    exit 1
fi

set -e

sub_help(){
    echo "Usage: $PROGNAME <subcommand> [options]"
    echo "Subcommands:"
    echo "    start    Start local instance of Antidote"
    echo "    reload   Reload Antidote components"
    echo "    stop     Stop local instance of Antidote"
    echo "    resume   Resume stopped Antidote instance"
    echo ""
    echo "options:"
    echo "-h    show brief help"
    echo ""
    echo "For help with each subcommand run:"
    echo "$PROGNAME <subcommand> -h|--help"
    echo ""
}
  
sub_resume(){

    minikube config set WantReportErrorPrompt false
    if [ ! -f $HOME/.minikube/config/config.json ]; then
        echo -e "${RED}No existing cluster detected.${NC}"
        echo -e "This subcommand is used to resume an existing selfmedicate setup."
        echo -e "Please use the ${WHITE}'start'${NC} subcommand instead."
        exit 1
    fi

    minikube start \
        --mount --mount-string="$LESSON_DIRECTORY:/antidote" \
        --cpus 4 --memory 8192 --network-plugin=cni --extra-config=kubelet.network-plugin=cni

    echo "About to modify /etc/hosts to add record for 'antidote-local' at IP address $(minikube ip)."
    echo "You will now be prompted for your sudo password."
    sudo sed -i '/antidote-local.*/d' /etc/hosts  > /dev/null
    echo "$(minikube ip)    antidote-local" | sudo tee -a /etc/hosts  > /dev/null
    echo -e "${GREEN}Finished!${NC} Antidote should now be available at http://antidote-local:30001/"
}

sub_start(){

    if [ -z "$LESSON_DIRECTORY" ]
    then
        echo -e "${RED}Error${NC} - Must provide lesson directory as the final parameter"
    fi

    if [ ! -d "$LESSON_DIRECTORY/lessons" ]; then
        echo -e "${RED}Error${NC} - $LESSON_DIRECTORY doesn't look like a proper curriculum directory."
        echo -e "Either this directory wasn't found, or the subdirectory 'lessons' within that directory wasn't found.\n"
        echo -e "In either case, this script cannot continue. Please either place the appropriate directory in place, or"
        echo -e "edit the LESSON_DIRECTORY variable at the top of this script."
        exit 1
    fi

    if [ -f $HOME/.minikube/config/config.json ]; then
        echo -e "${RED}WARNING - EXISTING MINIKUBE CONFIGURATION DETECTED${NC}"
        echo -e "This command is designed to start a new minikube cluster from scratch, and must delete any existing configurations in order to move forward."
        read -p "Press any key to DESTROY THE EXISTING CLUSTER and create a new one for antidote (Ctrl+C will escape)."
        set +e
        minikube delete > /dev/null
        set -e
    fi

    if [ -d "~/.kube/config" ]; then
        if [ ! -f ~/.kube/premselfmedicate_bkp ]; then
            echo "Backing up existing kubeconfig to ~/.kube/premselfmedicate_bkp..."
            cp ~/.kube/config ~/.kube/premselfmedicate_bkp
        else
            echo "Existing kubeconfig backup found, not re-copying."
        fi
    fi

    echo "Creating minikube cluster. This can take a few minutes, please be patient..."
    minikube config set WantReportErrorPrompt false
    minikube start \
    --mount --mount-string="$LESSON_DIRECTORY:/antidote" \
    --cpus 4 --memory 8192 --network-plugin=cni --extra-config=kubelet.network-plugin=cni

    set +e
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $(minikube ssh-key) \
        manifests/multus-cni.conf docker@$(minikube ip):/home/docker/multus.conf  > /dev/null 2>&1
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $(minikube ssh-key) -t docker@$(minikube ip) \
        "sudo cp /home/docker/multus.conf /etc/cni/net.d/1-multus.conf"  > /dev/null 2>&1
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $(minikube ssh-key) -t docker@$(minikube ip) \
        "sudo systemctl restart localkube"  > /dev/null 2>&1
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $(minikube ssh-key) -t docker@$(minikube ip) \
        "sudo curl -L https://github.com/nre-learning/plugins/blob/master/bin/antibridge?raw=true -o /opt/cni/bin/antibridge && sudo chmod a+x /opt/cni/bin/antibridge"  > /dev/null 2>&1
    set -e

    echo -e "\nThe minikube cluster ${WHITE}is now online${NC}. Now, we need to add some additional infrastructure components.\n"
    echo -e "\n${YELLOW}This will take some time${NC} - this script will pre-download large images so that you don't have to later. BE PATIENT.\n"

    kubectl apply -f "https://cloud.weave.works/k8s/net?k8s-version=$(kubectl version | base64 | tr -d '\n')" > /dev/null
    kubectl create -f manifests/multusinstall.yml > /dev/null

    print_progress() {
        percentage=$1
        chars=$(echo "40 * $percentage"/1| bc)
        v=$(printf "%-${chars}s" "#")
        s=$(printf "%-$((40 - chars))s")
        echo "${v// /#}""${s// /-}"
    }

    running_system_pods=0
    total_system_pods=$(kubectl get pods -n=kube-system | tail -n +2 | wc -l)
    while [ $running_system_pods -lt $total_system_pods ]
    do
        running_system_pods=$(kubectl get pods -n=kube-system | grep Running | wc -l)
        percentage="$( echo "$running_system_pods/$total_system_pods" | bc -l )"
        echo -ne $(print_progress $percentage) "${YELLOW}Installing additional infrastructure components...${NC}\r"
        sleep 1
    done

    # Clear line and print finished progress
    echo -ne "$pc%\033[0K\r"
    echo -ne $(print_progress 1) "${GREEN}Done.${NC}\n"

    kubectl create -f manifests/nginx-controller.yaml > /dev/null
    kubectl create -f manifests/syringe-k8s.yaml > /dev/null
    kubectl create -f manifests/antidote-web.yaml > /dev/null

    running_platform_pods=0
    total_platform_pods=$(kubectl get pods | tail -n +2 | wc -l)
    while [ $running_platform_pods -lt $total_platform_pods ]
    do
        running_platform_pods=$(kubectl get pods | grep Running | wc -l)
        percentage="$( echo "$running_platform_pods/$total_platform_pods" | bc -l )"
        echo -ne $(print_progress $percentage) "${YELLOW}Starting the antidote platform...${NC}\r"
        sleep 1
    done

    # Clear line and print finished progress
    echo -ne "$pc%\033[0K\r"
    echo -ne $(print_progress 1) "${GREEN}Done.${NC}\n"

    # Pre-download large common images
    declare -a images=("vqfx:snap1" "vqfx:snap2" "vqfx:snap3" "utility")
    for i in "${images[@]}"
    do
        echo -ne $(print_progress $percentage) "${YELLOW}Pre-emptively pulling image antidotelabs/$i...${NC}\r"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i $(minikube ssh-key) -t docker@$(minikube ip) \
                "docker pull antidotelabs/$i" > /dev/null 2>&1

        # Clear line and print finished progress
        echo -ne "$pc%\033[0K\r"
        echo -ne $(print_progress 1) "${GREEN}Done.${NC}\n"
    done

    echo "About to modify /etc/hosts to add record for 'antidote-local' at IP address $(minikube ip)."
    echo "You will now be prompted for your sudo password."
    sudo sed -i '/antidote-local.*/d' /etc/hosts  > /dev/null
    echo "$(minikube ip)    antidote-local" | sudo tee -a /etc/hosts  > /dev/null

    echo -e "${GREEN}Finished!${NC} Antidote should now be available at http://antidote-local:30001/"
}

sub_reload(){
    echo "Reloading lesson content, please wait..."
    kubectl delete pod $(kubectl get pods | grep syringe | awk '{ print $1 }') >> /dev/null
    while [ $(kubectl get ns -L syringeManaged | grep yes | wc -l) -gt 0 ]
    do
        echo "Waiting for running lessons to terminate..."
        sleep 1
    done
    echo -e "${GREEN}Reload complete.${NC}"
}

sub_stop(){
    echo -e "About to stop minikube. You may safely ignore any messages that say 'Errors occurred deleting mount process'"
    minikube stop
}

while getopts "h" OPTION
do
	case $OPTION in
		h)
            sub_help
            exit
            ;;
		\?)
			sub_help
			exit
			;;
	esac
done

# Direct to appropriate subcommand
subcommand=$1
case $subcommand in
    *)
        shift
        sub_${subcommand} $@
        if [ $? = 127 ]; then
            echo "Error: '$subcommand' is not a known subcommand." >&2
            echo "       Run '$PROGNAME --help' for a list of known subcommands." >&2
            exit 1
        fi
        ;;
esac

exit 0

