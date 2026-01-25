## Data class representing the result of an HTTP request
## Encapsulates success/failure state, response data, and error information
class_name HTTPResult
extends RefCounted


## Whether the request was successful
var success: bool = false

## HTTP status code (e.g., 200, 404, 500)
var status_code: int = 0

## Parsed JSON data from response body (null if parsing failed or no body)
var data: Variant = null

## Raw response body as string
var body: String = ""

## Error message if request failed
var error_message: String = ""

## Error type for categorizing failures
var error_type: ErrorType = ErrorType.NONE

## Response headers
var headers: Dictionary = {}


## Error type enumeration
enum ErrorType {
	NONE,
	CONNECTION_REFUSED,
	TIMEOUT,
	DNS_FAILURE,
	SSL_ERROR,
	HTTP_ERROR,
	PARSE_ERROR,
	UNKNOWN
}


## Create a successful result with parsed data
static func ok(status: int, response_data: Variant, raw_body: String = "", response_headers: Dictionary = {}) -> HTTPResult:
	var result := HTTPResult.new()
	result.success = true
	result.status_code = status
	result.data = response_data
	result.body = raw_body
	result.headers = response_headers
	return result


## Create an error result
static func error(error_msg: String, err_type: ErrorType = ErrorType.UNKNOWN, status: int = 0) -> HTTPResult:
	var result := HTTPResult.new()
	result.success = false
	result.status_code = status
	result.error_message = error_msg
	result.error_type = err_type
	return result


## Create a result from HTTP error code
static func from_http_error(http_error: int) -> HTTPResult:
	var error_msg: String
	var err_type: ErrorType

	match http_error:
		HTTPRequest.RESULT_CANT_CONNECT:
			error_msg = "Cannot connect to server"
			err_type = ErrorType.CONNECTION_REFUSED
		HTTPRequest.RESULT_CANT_RESOLVE:
			error_msg = "Cannot resolve hostname"
			err_type = ErrorType.DNS_FAILURE
		HTTPRequest.RESULT_CONNECTION_ERROR:
			error_msg = "Connection error"
			err_type = ErrorType.CONNECTION_REFUSED
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			error_msg = "TLS handshake error"
			err_type = ErrorType.SSL_ERROR
		HTTPRequest.RESULT_NO_RESPONSE:
			error_msg = "No response from server"
			err_type = ErrorType.TIMEOUT
		HTTPRequest.RESULT_BODY_SIZE_LIMIT_EXCEEDED:
			error_msg = "Response body too large"
			err_type = ErrorType.HTTP_ERROR
		HTTPRequest.RESULT_REQUEST_FAILED:
			error_msg = "Request failed"
			err_type = ErrorType.HTTP_ERROR
		HTTPRequest.RESULT_TIMEOUT:
			error_msg = "Request timed out"
			err_type = ErrorType.TIMEOUT
		_:
			error_msg = "Unknown error (code: %d)" % http_error
			err_type = ErrorType.UNKNOWN

	return HTTPResult.error(error_msg, err_type)


## Check if this is an HTTP client error (4xx)
func is_client_error() -> bool:
	return status_code >= 400 and status_code < 500


## Check if this is an HTTP server error (5xx)
func is_server_error() -> bool:
	return status_code >= 500 and status_code < 600


## Get a human-readable description of the result
func get_description() -> String:
	if success:
		return "Success (HTTP %d)" % status_code
	else:
		return "Error: %s (HTTP %d)" % [error_message, status_code]


## Convert to dictionary for debugging
func to_dict() -> Dictionary:
	return {
		"success": success,
		"status_code": status_code,
		"data": data,
		"body": body,
		"error_message": error_message,
		"error_type": ErrorType.keys()[error_type],
		"headers": headers
	}
