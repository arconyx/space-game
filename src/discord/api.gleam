import discord/types.{type Bot}
import gleam/dynamic/decode
import gleam/hackney
import gleam/http.{type Method}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/result
import logging

// TODO: Rate limiting
// https://discord.com/developers/docs/topics/rate-limits#rate-limits

pub fn default_headers(req: Request(a)) -> Request(a) {
  req
  |> request.set_header(
    "user-agent",
    "space-game (https://github.com/arconyx/space-game, v0.1)",
  )
  |> request.set_header("content-type", "application/json")
}

/// Construct a request object 
pub fn request(
  auth_token token: String,
  method method: Method,
  endpoint endpoint: String,
  payload payload: Option(Json),
) -> Request(String) {
  request.new()
  |> request.set_body(case payload {
    Some(data) -> json.to_string(data)
    None -> ""
  })
  |> default_headers
  |> request.set_header("authorization", "Bot " <> token)
  |> request.set_host("discord.com")
  |> request.set_method(method)
  |> request.set_path(
    "/api/v10/"
    <> case endpoint {
      "/" <> path -> path
      path -> path
    },
  )
  |> request.set_scheme(http.Https)
}

pub fn get(bot: Bot, endpoint: String) -> Request(String) {
  request(auth_token: bot.token, method: http.Get, endpoint:, payload: None)
}

pub fn get_with_token(token: String, endpoint: String) -> Request(String) {
  request(auth_token: token, method: http.Get, endpoint:, payload: None)
}

pub fn put(bot: Bot, endpoint: String, payload: Json) -> Request(String) {
  request(
    auth_token: bot.token,
    method: http.Put,
    endpoint:,
    payload: Some(payload),
  )
}

pub fn post(bot: Bot, endpoint: String, payload: Json) -> Request(String) {
  request(
    auth_token: bot.token,
    method: http.Post,
    endpoint:,
    payload: Some(payload),
  )
}

pub fn patch(bot: Bot, endpoint: String, payload: Json) -> Request(String) {
  request(
    auth_token: bot.token,
    method: http.Patch,
    endpoint:,
    payload: Some(payload),
  )
}

pub type ErrorCode {
  // 400
  BadRequest
  // 401
  Unauthorised
  // 403
  Forbidden
  // 404
  NotFound
  // 405
  MethodNotAllowed
  // 429
  TooManyRequests
  // 502
  GatewayUnavailable
  // 5xx
  ServerError(Int)
  // Catchall
  Unrecognised(Int)
}

/// Errors when sending requests
pub type Error {
  Transmission(hackney.Error)
  ResponseCode(ErrorCode)
  DecodeError(json.DecodeError)
}

/// Actually send a request to the server
pub fn send(req: Request(String)) -> Result(Response(String), Error) {
  use resp <- result.try(hackney.send(req) |> result.map_error(Transmission))
  case resp.status {
    200 | 201 | 204 | 304 -> resp |> Ok
    400 -> BadRequest |> Error
    401 -> Unauthorised |> Error
    403 -> Forbidden |> Error
    404 -> NotFound |> Error
    405 -> MethodNotAllowed |> Error
    429 -> TooManyRequests |> Error
    502 -> GatewayUnavailable |> Error
    c if 499 < c && c < 600 -> ServerError(c) |> Error
    c if 199 < c && c < 300 -> {
      logging.log(
        logging.Warning,
        "Got unexpected success code " <> int.to_string(c) <> " for request",
      )
      resp |> Ok
    }
    c -> Unrecognised(c) |> Error
  }
  |> result.map_error(ResponseCode)
}

pub fn send_and_decode(
  req: Request(String),
  decoder: decode.Decoder(a),
) -> Result(a, Error) {
  case send(req) {
    Ok(resp) -> json.parse(resp.body, decoder) |> result.map_error(DecodeError)
    Error(e) -> Error(e)
  }
}
