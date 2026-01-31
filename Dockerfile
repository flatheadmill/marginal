# syntax=docker/dockerfile:1.3-labs
FROM harbor.acreops.org/acreops/shell-operator:v1.12.3
RUN apk --no-progress update && apk --no-progress add gojq jo zsh gawk sed
RUN sed --help
ADD hooks/ /hooks/
