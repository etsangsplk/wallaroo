use "collections"
use "net"
use "sendence/guid"
use "wallaroo/fail"
use "wallaroo/messages"
use "wallaroo/metrics"
use "wallaroo/network"
use "wallaroo/source"
use "wallaroo/sink"
use "wallaroo/state"
use "wallaroo/tcp_sink"
use "wallaroo/tcp_source"
use "wallaroo/recovery"
use "wallaroo/routing"
use "wallaroo/topology"

class Application
  let _name: String
  let pipelines: Array[BasicPipeline] = Array[BasicPipeline]
  // _state_builders maps from state_name to StateSubpartition
  let _state_builders: Map[String, PartitionBuilder val] =
    _state_builders.create()
  // Map from source id to filename
  let init_files: Map[USize, InitFile val] = init_files.create()
  // TODO: Replace this default strategy with a better one after POC
  var default_target: (Array[RunnerBuilder val] val | None) = None
  var default_state_name: String = ""
  var default_target_id: U128 = 0
  var sink_count: USize = 0

  new create(name': String) =>
    _name = name'

  fun ref new_pipeline[In: Any val, Out: Any val] (
    pipeline_name: String, source_config: SourceConfig[In],
    init_file: (InitFile val | None) = None, coalescing: Bool = true):
      PipelineBuilder[In, Out, In]
  =>
    let pipeline_id = pipelines.size()
    match init_file
    | let f: InitFile val =>
      add_init_file(pipeline_id, f)
    end
    let pipeline = Pipeline[In, Out](_name, pipeline_id, pipeline_name,
      source_config, coalescing)
    PipelineBuilder[In, Out, In](this, pipeline)

  // TODO: Replace this with a better approach.  This is a shortcut to get
  // the POC working and handle unknown bucket in the partition.
  fun ref partition_default_target[In: Any val, Out: Any val,
    S: State ref](
    pipeline_name: String,
    default_name: String,
    s_comp: StateComputation[In, Out, S] val,
    s_initializer: StateBuilder[S] val): Application
  =>
    default_state_name = default_name

    let builders: Array[RunnerBuilder val] trn =
      recover Array[RunnerBuilder val] end

    let pre_state_builder = PreStateRunnerBuilder[In, Out, In, U8, S](
      s_comp, default_name, SingleStepPartitionFunction[In],
      TypedRouteBuilder[StateProcessor[S] val],
      TypedRouteBuilder[Out], TypedRouteBuilder[In])
    builders.push(pre_state_builder)

    let state_builder' = StateRunnerBuilder[S](s_initializer, default_name, s_comp.state_change_builders(),
      TypedRouteBuilder[Out])
    builders.push(state_builder')

    default_target = consume builders
    default_target_id = pre_state_builder.id()

    this

  fun ref add_pipeline(p: BasicPipeline) =>
    pipelines.push(p)

  fun ref add_init_file(source_id: USize, init_file: InitFile val) =>
    init_files(source_id) = init_file

  fun ref add_state_builder(state_name: String,
    state_partition: PartitionBuilder val)
  =>
    _state_builders(state_name) = state_partition

  fun ref increment_sink_count() =>
    sink_count = sink_count + 1

  fun state_builder(state_name: String): PartitionBuilder val ? =>
    _state_builders(state_name)
  fun state_builders(): Map[String, PartitionBuilder val] val =>
    let builders: Map[String, PartitionBuilder val] trn =
      recover Map[String, PartitionBuilder val] end
    for (k, v) in _state_builders.pairs() do
      builders(k) = v
    end
    consume builders

  fun name(): String => _name

trait BasicPipeline
  fun name(): String
  fun source_id(): USize
  fun source_builder(): SourceBuilderBuilder ?
  fun source_route_builder(): RouteBuilder val
  fun source_listener_builder_builder(): SourceListenerBuilderBuilder
  fun sink_builder(): (SinkBuilder | None)
  // TODO: Change this when we need more sinks per pipeline
  // ASSUMPTION: There is at most one sink per pipeline
  fun sink_id(): (U128 | None)
  // The index into the list of provided sink addresses
  fun is_coalesced(): Bool
  fun apply(i: USize): RunnerBuilder val ?
  fun size(): USize

class Pipeline[In: Any val, Out: Any val] is BasicPipeline
  let _pipeline_id: USize
  let _name: String
  let _app_name: String
  let _runner_builders: Array[RunnerBuilder val]
  var _source_builder: (SourceBuilderBuilder | None) = None
  let _source_route_builder: RouteBuilder val
  let _source_listener_builder_builder: SourceListenerBuilderBuilder
  var _sink_builder: (SinkBuilder | None) = None

  var _sink_id: (U128 | None) = None
  let _is_coalesced: Bool

  new create(app_name: String, p_id: USize, n: String,
    sc: SourceConfig[In], coalescing: Bool)
  =>
    _pipeline_id = p_id
    _runner_builders = Array[RunnerBuilder val]
    _name = n
    _app_name = app_name
    _source_route_builder = TypedRouteBuilder[In]
    _is_coalesced = coalescing
    _source_listener_builder_builder = sc.source_listener_builder_builder()
    _source_builder = sc.source_builder(_app_name, _name)

  fun ref add_runner_builder(p: RunnerBuilder val) =>
    _runner_builders.push(p)

  fun apply(i: USize): RunnerBuilder val ? => _runner_builders(i)

  fun ref update_sink(sink_builder': SinkBuilder) =>
    _sink_builder = sink_builder'

  fun source_id(): USize => _pipeline_id

  fun source_builder(): SourceBuilderBuilder ? =>
    _source_builder as SourceBuilderBuilder

  fun source_route_builder(): RouteBuilder val => _source_route_builder

  fun source_listener_builder_builder(): SourceListenerBuilderBuilder =>
    _source_listener_builder_builder

  fun sink_builder(): (SinkBuilder | None) => _sink_builder

  // TODO: Change this when we need more sinks per pipeline
  // ASSUMPTION: There is at most one sink per pipeline
  fun sink_id(): (U128 | None) => _sink_id

  fun ref update_sink_id() =>
    _sink_id = GuidGenerator.u128()

  fun is_coalesced(): Bool => _is_coalesced

  fun size(): USize => _runner_builders.size()

  fun name(): String => _name

class PipelineBuilder[In: Any val, Out: Any val, Last: Any val]
  let _a: Application
  let _p: Pipeline[In, Out]

  new create(a: Application, p: Pipeline[In, Out]) =>
    _a = a
    _p = p

  fun ref to[Next: Any val](
    comp_builder: ComputationBuilder[Last, Next] val,
    id: U128 = 0): PipelineBuilder[In, Out, Next]
  =>
    let next_builder = ComputationRunnerBuilder[Last, Next](comp_builder,
      TypedRouteBuilder[Next])
    _p.add_runner_builder(next_builder)
    PipelineBuilder[In, Out, Next](_a, _p)

  fun ref to_parallel[Next: Any val](
    comp_builder: ComputationBuilder[Last, Next] val,
    id: U128 = 0): PipelineBuilder[In, Out, Next]
  =>
    let next_builder = ComputationRunnerBuilder[Last, Next](
      comp_builder, TypedRouteBuilder[Next] where parallelized' = true)
    _p.add_runner_builder(next_builder)
    PipelineBuilder[In, Out, Next](_a, _p)

  fun ref to_stateful[Next: Any val, S: State ref](
    s_comp: StateComputation[Last, Next, S] val,
    s_initializer: StateBuilder[S] val,
    state_name: String): PipelineBuilder[In, Out, Next]
  =>
    // TODO: This is a shortcut. Non-partitioned state is being treated as a
    // special case of partitioned state with one partition. This works but is
    // a bit confusing when reading the code.
    let guid_gen = GuidGenerator
    let single_step_partition = Partition[Last, U8](
      SingleStepPartitionFunction[Last], recover [0] end)
    let step_id_map: Map[U8, U128] trn = recover Map[U8, U128] end

    step_id_map(0) = guid_gen.u128()


    let next_builder = PreStateRunnerBuilder[Last, Next, Last, U8, S](
      s_comp, state_name, SingleStepPartitionFunction[Last],
      TypedRouteBuilder[StateProcessor[S] val],
      TypedRouteBuilder[Next])

    _p.add_runner_builder(next_builder)

    let state_builder = PartitionedStateRunnerBuilder[Last, S, U8](_p.name(),
      state_name, consume step_id_map, single_step_partition,
      StateRunnerBuilder[S](s_initializer, state_name,
        s_comp.state_change_builders()),
      TypedRouteBuilder[StateProcessor[S] val],
      TypedRouteBuilder[Next])

    _a.add_state_builder(state_name, state_builder)

    PipelineBuilder[In, Out, Next](_a, _p)

  fun ref to_state_partition[PIn: Any val,
    Key: (Hashable val & Equatable[Key]), Next: Any val = PIn,
    S: State ref](
      s_comp: StateComputation[Last, Next, S] val,
      s_initializer: StateBuilder[S] val,
      state_name: String,
      partition: Partition[PIn, Key] val,
      multi_worker: Bool = false,
      default_state_name: String = ""
    ): PipelineBuilder[In, Out, Next]
  =>
    let guid_gen = GuidGenerator
    let step_id_map: Map[Key, U128] trn = recover Map[Key, U128] end

    match partition.keys()
    | let wks: Array[WeightedKey[Key]] val =>
      for wkey in wks.values() do
        step_id_map(wkey._1) = guid_gen.u128()
      end
    | let ks: Array[Key] val =>
      for key in ks.values() do
        step_id_map(key) = guid_gen.u128()
      end
    end

    let next_builder = PreStateRunnerBuilder[Last, Next, PIn, Key, S](
      s_comp, state_name, partition.function(),
      TypedRouteBuilder[StateProcessor[S] val],
      TypedRouteBuilder[Next] where multi_worker = multi_worker,
      default_state_name' = default_state_name)

    _p.add_runner_builder(next_builder)

    let state_builder = PartitionedStateRunnerBuilder[PIn, S,
      Key](_p.name(), state_name, consume step_id_map, partition,
        StateRunnerBuilder[S](s_initializer, state_name,
          s_comp.state_change_builders()),
        TypedRouteBuilder[StateProcessor[S] val],
        TypedRouteBuilder[Next]
        where multi_worker = multi_worker, default_state_name' =
        default_state_name)

    _a.add_state_builder(state_name, state_builder)

    PipelineBuilder[In, Out, Next](_a, _p)

  fun ref done(): Application ? =>
    _a.add_pipeline(_p as BasicPipeline)
    _a

  fun ref to_sink(sink_information: SinkConfig[Out]): Application ? =>
    let sink_builder = sink_information()
    _a.increment_sink_count()
    _p.update_sink(sink_builder)
    _p.update_sink_id()
    _a.add_pipeline(_p as BasicPipeline)
    _a
