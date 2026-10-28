/// Lifecycle states of every background service PALLSQL manages.
///
/// A service is never described by a single boolean: starting/stopping are
/// real transitions and `unavailable` is used when the runtime is not present
/// at all (for example a missing PHP binary).
enum ServiceState {
  stopped,
  starting,
  running,
  stopping,
  error,
  unavailable,
}

extension ServiceStateX on ServiceState {
  String get label {
    switch (this) {
      case ServiceState.stopped:
        return 'Stopped';
      case ServiceState.starting:
        return 'Starting';
      case ServiceState.running:
        return 'Running';
      case ServiceState.stopping:
        return 'Stopping';
      case ServiceState.error:
        return 'Error';
      case ServiceState.unavailable:
        return 'Unavailable';
    }
  }

  /// `true` only while the service is actually serving traffic.
  bool get isRunning => this == ServiceState.running;

  /// `true` while a start/stop operation is in flight.
  bool get isTransitional =>
      this == ServiceState.starting || this == ServiceState.stopping;

  /// `true` when a start action makes sense.
  bool get canStart =>
      this == ServiceState.stopped || this == ServiceState.error;

  /// `true` when a stop action makes sense.
  bool get canStop =>
      this == ServiceState.running ||
      this == ServiceState.starting ||
      this == ServiceState.error;
}

/// Immutable status snapshot of a single service.
class ServiceStatus {
  const ServiceStatus(this.state, {this.message, this.updatedAt});

  const ServiceStatus.stopped({this.message})
      : state = ServiceState.stopped,
        updatedAt = null;

  const ServiceStatus.unavailable(String reason)
      : state = ServiceState.unavailable,
        message = reason,
        updatedAt = null;

  const ServiceStatus.running({this.message})
      : state = ServiceState.running,
        updatedAt = null;

  const ServiceStatus.error(String reason)
      : state = ServiceState.error,
        message = reason,
        updatedAt = null;

  final ServiceState state;
  final String? message;
  final DateTime? updatedAt;

  ServiceState get value => state;
  bool get isRunning => state.isRunning;
  bool get isBusy => state.isTransitional;
  bool get canStart => state.canStart;
  bool get canStop => state.canStop;
  String get label => state.label;

  ServiceStatus copyWith({
    ServiceState? state,
    String? message,
    DateTime? updatedAt,
    bool clearMessage = false,
  }) {
    return ServiceStatus(
      state ?? this.state,
      message: clearMessage ? null : (message ?? this.message),
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  String toString() => 'ServiceStatus(${state.name}${message == null ? '' : ', '
      '$message'})';
}

/// Aggregate state used by the dashboard "Start all" / "Stop all" actions.
class ServiceAggregate {
  const ServiceAggregate({
    required this.webServer,
    required this.phpRuntime,
    required this.database,
  });

  final ServiceStatus webServer;
  final ServiceStatus phpRuntime;
  final ServiceStatus database;

  bool get allRunning => webServer.isRunning && database.isRunning;

  bool get anyBusy => webServer.isBusy || phpRuntime.isBusy || database.isBusy;

  bool get canStartAll => !anyBusy && (!webServer.isRunning || !database.isRunning);

  bool get canStopAll => !anyBusy && (webServer.canStop || database.canStop);

  ServiceState get overallState {
    if (webServer.isBusy || database.isBusy) {
      return webServer.isBusy ? webServer.state : database.state;
    }
    if (webServer.state == ServiceState.error ||
        database.state == ServiceState.error) {
      return ServiceState.error;
    }
    if (webServer.isRunning) {
      return ServiceState.running;
    }
    return ServiceState.stopped;
  }

  String get overallLabel {
    switch (overallState) {
      case ServiceState.running:
        return 'Environment online';
      case ServiceState.starting:
        return 'Starting environment';
      case ServiceState.stopping:
        return 'Stopping environment';
      case ServiceState.error:
        return 'Environment error';
      case ServiceState.stopped:
        return 'Environment offline';
      case ServiceState.unavailable:
        return 'Environment unavailable';
    }
  }
}
