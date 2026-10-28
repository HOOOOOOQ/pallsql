enum ServiceState { stopped, starting, running, stopping, error, unavailable }

class ServiceStatus {
  const ServiceStatus(this.state, {this.message});
  final ServiceState state;
  final String? message;
  bool get isRunning => state == ServiceState.running;
  bool get canStart => state == ServiceState.stopped || state == ServiceState.error;
  String get label => switch (state) {
        ServiceState.stopped => 'Stopped',
        ServiceState.starting => 'Starting',
        ServiceState.running => 'Running',
        ServiceState.stopping => 'Stopping',
        ServiceState.error => 'Error',
        ServiceState.unavailable => 'Unavailable',
      };
}
