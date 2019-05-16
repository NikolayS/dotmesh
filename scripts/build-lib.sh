#!/usr/bin/env bash
set -xe

location=$(realpath .)/bazel-bin/cmd

bazel-with-workspace() {
    cmd=$1
    cmd_path=$2
    platform=${3:-linux_amd64}
    bazel $cmd $cmd_path --platforms=@io_bazel_rules_go//go/toolchain:$platform --workspace_status_command=$(realpath ./version_status.sh)
}

bazel-with-workspace-no-run() {
    cmd_path=$1
    platform=${2:-linux_amd64}
    bazel run $cmd_path --platforms=@io_bazel_rules_go//go/toolchain:$platform --workspace_status_command=$(realpath ./version_status.sh) -- --norun
}

setup-target-dir() {
    rm -rf target/
    mkdir -p target/
}

set-defaults() {
    if [ -z "$CI_DOCKER_TAG" ]; then
    # Non-CI build
        export STABLE_DOCKERTAG=latest
    else
        export STABLE_DOCKERTAG=$CI_DOCKER_TAG
    fi

    export REGISTRY=${CI_REGISTRY:-$(hostname).local:80}
    export REPOSITORY=${CI_REPOSITORY:-dotmesh}

    export STABLE_VERSION=$(cd cmd/versioner && go run versioner.go)

    if [ -z "$CI_DOCKER_SERVER_IMAGE" ]; then
        # Non-CI build
        export STABLE_CI_DOCKER_SERVER_IMAGE=${REGISTRY}/${REPOSITORY}/dotmesh-server:${STABLE_DOCKERTAG}
    fi
}

build-client() {
    OS=${1:-Linux}
    if [ $OS = "Linux" ]; then 
        platform="linux_amd64"
    elif [ $OS = "Darwin" ]; then 
        platform="darwin_amd64"
    else
        echo "Please enter Linux or Darwin as the first arg"
        return 1
    fi

    output_dir=${platform}_static_stripped
    rm -rf binaries/$OS || true
    mkdir -p binaries/$OS/

    if [ x$CI_DOCKER_TAG == x ]
    then
        # Non-CI build
        CI_DOCKER_TAG=$VERSION
    fi

    path=${location}/dm/$output_dir/dm
    bazel-with-workspace build //cmd/dm:dm $platform
    # tiny bit hacky - if we're on a mac and compiling for linux the output will be "pure", and vice versa compiling for mac from linux
    if [ ! -d "${location}/dm/${output_dir}" ]; then
        output_dir=${platform}_static_pure_stripped
    fi
    cp ${location}/dm/$output_dir/dm binaries/$OS/
    return 0
}

build-server() {
    # downloading docker and putting zfs into place is hard in bazel, so cheating using docker :(
    docker build -f cmd/dotmesh-server/Dockerfile -t "base-image-dotmesh" cmd/dotmesh-server
    docker save base-image-dotmesh > dotmesh-base.tar

    # skip rebuilding Kubernetes components if not using them
    if [ -z "${SKIP_K8S}" ]; then
        # dind-provisioner (builds a container)
        echo "building dind-provisioner container"
        # todo switch back to build when bazel can push without being annoying
        bazel-with-workspace build //cmd/dotmesh-server/pkg/dind-dynamic-provisioning:dind-dynamic-provisioner
        bazel-with-workspace-no-run //cmd/dotmesh-server/pkg/dind-dynamic-provisioning:dind-dynamic-provisioner
    fi

    # dotmesh-server
    echo "Building dotmesh-server container"
    # TODO serverVersion?
    # bazel-with-workspace build //cmd/dotmesh-server:dotmesh-server-img
    # fixme hack so that we don't have to use bazel to do pushing, which seems to flake :(
    bazel-with-workspace build //cmd/dotmesh-server:dotmesh-server-img
    bazel-with-workspace-no-run //cmd/dotmesh-server:dotmesh-server-img
    # if [ -n "${GENERATE_LOCAL_DOCKER_IMAGE}" ]; then
    #     # set this variable if you need the generated image to show up in docker images
    #     bazel-with-workspace run //cmd/dotmesh-server:dotmesh-server-img
    # fi
    
    # allow disabling of registry push
    if [ -z "${NO_PUSH}" ]; then
        echo "pushing images"
        #fixme get back to using bazel for container pushes when it's not flaky.
        docker tag bazel/cmd/dotmesh-server:dotmesh-server-img $REGISTRY/$REPOSITORY/dotmesh-server:$STABLE_DOCKERTAG
        docker push $REGISTRY/$REPOSITORY/dotmesh-server:$STABLE_DOCKERTAG
        #bazel-with-workspace run //cmd/dotmesh-server:dotmesh-server_push
        if [ -z "${SKIP_K8S}" ]; then
            echo "pushing dind provisioner"
            docker tag bazel/cmd/dotmesh-server/pkg/dind-dynamic-provisioning:dind-dynamic-provisioner $REGISTRY/$REPOSITORY/dind-dynamic-provisioner:$STABLE_DOCKERTAG
            docker push $REGISTRY/$REPOSITORY/dind-dynamic-provisioner:$STABLE_DOCKERTAG
            #bazel-with-workspace run //cmd/dotmesh-server/pkg/dind-dynamic-provisioning:dind_push
        fi
    fi

    bazel-with-workspace build //cmd/dotmesh-server/pkg/dind-flexvolume:dind-flexvolume
    setup-target-dir
    cp bazel-bin/cmd/dotmesh-server/pkg/dind-flexvolume/linux_amd64_pure_stripped/dind-flexvolume ./target/dind-flexvolume
}

build-provisioner() {
    # fixme switch back to bazel for pushing when it's not flaky
    bazel-with-workspace build //cmd/dynamic-provisioner:provisioner-img
    bazel-with-workspace-no-run //cmd/dynamic-provisioner:provisioner-img
    if [ -z "${NO_PUSH}" ]; then
        echo "pushing image"
        tag-then-push provisioner-img dotmesh-dynamic-provisioner dynamic-provisioner 
        #bazel-with-workspace run //cmd/dynamic-provisioner:provisioner_push
    fi
}

build-operator() {
    # operator (builds container)
    bazel-with-workspace build //cmd/operator:operator-img
    bazel-with-workspace-no-run //cmd/operator:operator-img
    if [ -z "${NO_PUSH}" ]; then
        echo "pushing image"
        tag-then-push operator-img dotmesh-operator operator
        #bazel-with-workspace run //cmd/operator:operator_push
    fi

}

tag-then-push() {
    target=$1
    img=$2
    dir=$3
    if [ -z $dir ]; then
        dir=$1
    fi
    docker tag bazel/cmd/$dir:$target $REGISTRY/$REPOSITORY/$img:$STABLE_DOCKERTAG
    docker push $REGISTRY/$REPOSITORY/$img:$STABLE_DOCKERTAG
}
