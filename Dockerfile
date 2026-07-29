FROM harbor.acreops.org/acreops/acrectl-operator:v0.4.0
ADD hooks/ /hooks/
# shell-operator runs every executable in /hooks; `hook` is the entry point, the
# .zsh files are sourced libraries and must not be run.
RUN chmod +x /hooks/hook && chmod -x /hooks/config.zsh /hooks/schedule.zsh /hooks/complete.zsh
