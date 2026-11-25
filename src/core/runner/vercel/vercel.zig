//! The Vercel side of the built-in remote runner: the login (R2, R3) and the
//! calls that setup makes (U5, U6, U8, R5). Outside this folder, code imports
//! only this file.

const credentials = @import("credentials.zig");
const transport = @import("transport.zig");
const api = @import("api.zig");
const stream = @import("stream.zig");
const reply = @import("reply.zig");
const sandbox = @import("sandbox.zig");
const attempt = @import("attempt.zig");
const sync = @import("sync.zig");
const exec = @import("exec.zig");
const bring_back = @import("bring_back.zig");

pub const Token = credentials.Token;
pub const AuthResult = credentials.AuthResult;
pub const Env = credentials.Env;
pub const Files = credentials.Files;
pub const Trace = credentials.Trace;
pub const disk = credentials.disk;
pub const load = credentials.load;

pub const override_env = transport.override_env;
pub const BaseUrl = transport.BaseUrl;
pub const resolveBaseUrl = transport.resolveBaseUrl;

pub const Link = api.Link;
pub const Outcome = api.Outcome;
pub const Failure = api.Failure;
pub const Team = api.Team;
pub const Project = api.Project;
pub const describe = api.describe;
pub const max_teams = api.max_teams;
pub const sandbox_project_name = api.sandbox_project_name;
pub const getUser = api.getUser;
pub const listTeams = api.listTeams;
pub const getTeamBySlug = api.getTeamBySlug;
pub const listProjects = api.listProjects;
pub const getProjectByName = api.getProjectByName;
pub const createProject = api.createProject;

pub const Stream = stream.Stream;
pub const StreamCall = stream.Call;
pub const StreamBody = stream.Body;
pub const StreamLimits = stream.Limits;
pub const StreamError = stream.StreamError;
pub const openStream = stream.open;
pub const callBuffered = stream.callBuffered;
pub const exec_limits = stream.exec_limits;
pub const bring_back_limits = stream.bring_back_limits;
pub const reattach_limits = stream.reattach_limits;
pub const fsWriteLimits = stream.fsWriteLimits;
pub const max_log_line_bytes = stream.max_log_line_bytes;

pub const SandboxOutcome = sandbox.Outcome;
pub const SandboxContext = sandbox.Context;
pub const SandboxCommand = sandbox.Command;
pub const SandboxSession = sandbox.Session;
pub const ensureSandbox = sandbox.ensure;
pub const runSandboxCommand = sandbox.runCommand;

pub const PushOptions = sync.Options;
pub const PushResult = sync.Result;
pub const pushRoot = sync.push;
pub const SandboxFailure = sandbox.Failure;
pub const loginRejected = attempt.loginRejected;

pub const ExecRequest = exec.Request;
pub const ExecPair = exec.Pair;
pub const ExecOutcome = exec.Outcome;
pub const ExecLimits = exec.Limits;
pub const runExec = exec.runRecovering;
pub const writeExtendNote = exec.writeExtendNote;
pub const extendTime = sandbox.extendTime;
pub const extendBeforeExec = sandbox.extendBeforeExec;
pub const session_ended_detail = sandbox.session_ended_detail;
pub const extend_below_ms = sandbox.extend_below_ms;

pub const bringBack = bring_back.run;
pub const BringBackInput = bring_back.Input;
pub const BringBackResult = bring_back.Result;
pub const BringBackReport = bring_back.Report;
pub const BringBackCounts = bring_back.Counts;
pub const BringBackFile = sandbox.BringBackFile;
pub const SizeNote = sandbox.SizeNote;
pub const bringBackBaseline = sync.bringBackBaseline;
pub const notePending = bring_back.notePending;
pub const isolated = @import("isolated.zig");
pub const createIsolated = sandbox.createIsolated;
pub const deleteSandboxNamed = sandbox.deleteSandboxNamed;
pub const prepareIsolatedRoot = sandbox.prepareIsolatedRoot;
pub const pushIsolated = sync.pushIsolated;
pub const bringBackIsolated = bring_back.runIsolated;

test {
    _ = credentials;
    _ = transport;
    _ = api;
    _ = stream;
    _ = reply;
    _ = sandbox;
    _ = attempt;
    _ = sync;
    _ = exec;
    _ = bring_back;
    _ = isolated;
}
