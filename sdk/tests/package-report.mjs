export function serializeError(error) {
  if (error == null) return null;
  return {
    name: error.name,
    code: error.code ?? null,
    message: error.message,
    stack: error.stack,
    ...(error instanceof AggregateError ? { errors: error.errors.map(serializeError) } : {}),
  };
}
