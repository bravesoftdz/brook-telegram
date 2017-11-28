unit brooktelegramaction;

{$mode objfpc}{$H+}

interface

uses
  BrookAction, tgtypes, tgsendertypes, sysutils, classes, tgstatlog, eventlog,
  ghashmap, fpjson;

type

  TCommandEvent = procedure (AReceiver: TBrookAction; const ACommand: String;
    AMessage: TTelegramMessageObj) of object;
  TCallbackEvent = procedure (AReceiver: TBrookAction; ACallback: TCallbackQueryObj) of object;
  TMessageEvent = procedure (AReceiver: TBrookAction; AMessage: TTelegramMessageObj) of object;

  { TStringHash }

  TStringHash = class
    class function hash(s: String; n: Integer): Integer;
  end;

  generic TStringHashMap<T> = class(specialize THashMap<String,T,TStringHash>) end;

  TCommandHandlersMap = specialize TStringHashMap<TCommandEvent>;

  { TWebhookAction }

  TWebhookAction = class(TBrookAction)
  private
    FCurrentChatID: Int64;
    FCurrentUser: TTelegramUserObj;
    FHelpText: String;
    FLogger: TEventLog;
    FOnCallbackQuery: TCallbackEvent;
    FOnUpdateMessage: TMessageEvent;
    FStartText: String;
    FStatLogger: TtgStatLog;
    FToken: String;
    FtgSender: TTelegramSender;
    FUpdateMessage: TTelegramUpdateObj;
    FUserPermissions: TStringList; // namevalue pairs UserID=Character
    FCommandHandlers: TCommandHandlersMap;
    function GetCommandHandlers(const Command: String): TCommandEvent;
    procedure SetCommandHandlers(const Command: String; AValue: TCommandEvent);
    procedure SetHelpText(AValue: String);
    procedure SetLogger(AValue: TEventLog);
    procedure SetOnCallbackQuery(AValue: TCallbackEvent);
    procedure SetOnUpdateMessage(AValue: TMessageEvent);
    procedure SetStartText(AValue: String);
    procedure SetStatLogger(AValue: TtgStatLog);
    procedure SetToken(AValue: String);
    procedure SetUpdateMessage(AValue: TTelegramUpdateObj);
    procedure DoCallbackQueryStat(SendFile: Boolean = False);
    procedure DoGetStat(ADate: TDate = 0; SendFile: Boolean = false);
    procedure DoStat(SDate: String = 'today'; SendFile: Boolean = false);
    procedure SendStatLog(ADate: TDate = 0; AReplyMarkup: TReplyMarkup = nil);
    procedure SendStatInlineKeyboard(SendFile: Boolean = false);
    procedure LogMessage(Sender: TObject; EventType: TEventType; const Msg: String);
    procedure StatLog(const AMessage: String; UpdateType: TUpdateType);
  protected
    function CreateInlineKeyboardStat(SendFile: Boolean): TJSONArray;
    procedure DoCallbackQuery; virtual;
    procedure DoMessageHandler; virtual;
    procedure EditOrSendMessage(const AMessage: String; AParseMode: TParseMode = pmDefault;
      ReplyMarkup: TReplyMarkup = nil; TryEdit: Boolean = False);
    function IsSimpleUser: Boolean;
  public
    constructor Create; override;
    destructor Destroy; override;
    procedure Post; override;
    property Token: String read FToken write SetToken;
    property OnCallbackQuery: TCallbackEvent read FOnCallbackQuery write SetOnCallbackQuery;
    property OnUpdateMessage: TMessageEvent read FOnUpdateMessage write SetOnUpdateMessage;
    property UpdateObj: TTelegramUpdateObj read FUpdateMessage write SetUpdateMessage;
    property UserPermissions: TStringList read FUserPermissions write FUserPermissions;
    property StartText: String read FStartText write SetStartText; // Text for /start command reply
    property HelpText: String read FHelpText write SetHelpText;  // Text for /help command reply
    property StatLogger: TtgStatLog read FStatLogger write SetStatLogger;
    property Logger: TEventLog read FLogger write SetLogger;
    property CurrentUser: TTelegramUserObj read FCurrentUser;
    property CurrentChatID: Int64 read FCurrentChatID;
    property Sender: TTelegramSender read FtgSender;
    property CommandHandlers [const Command: String]: TCommandEvent read GetCommandHandlers
      write SetCommandHandlers;  // It can create command handlers by assigning their to array elements
  end;

implementation

uses jsonparser, BrookHttpConsts, strutils, BrookApplication, jsonscanner;

const
  UpdateTypeAliases: array[TUpdateType] of PChar = ('message', 'callback_query');
  StatDateFormat = 'dd-mm-yyyy';

{ TStringHash }

class function TStringHash.hash(s: String; n: Integer): Integer;
var
  c: Char;
begin
  Result := 0;
  for c in s do
    Inc(Result,Ord(c));
  Result := Result mod n;
end;

procedure TWebhookAction.SetUpdateMessage(AValue: TTelegramUpdateObj);
begin
  if FUpdateMessage=AValue then Exit;
  FUpdateMessage:=AValue;
end;

procedure TWebhookAction.SetToken(AValue: String);
begin
  if FToken=AValue then Exit;
  FToken:=AValue;
  if Assigned(FtgSender) then
    FtgSender.Token:=FToken;
end;

procedure TWebhookAction.SetStartText(AValue: String);
begin
  if FStartText=AValue then Exit;
  FStartText:=AValue;
end;

procedure TWebhookAction.SetStatLogger(AValue: TtgStatLog);
begin
  if FStatLogger=AValue then Exit;
  FStatLogger:=AValue;
end;

procedure TWebhookAction.SetOnCallbackQuery(AValue: TCallbackEvent);
begin
  if FOnCallbackQuery=AValue then Exit;
  FOnCallbackQuery:=AValue;
end;

procedure TWebhookAction.SetOnUpdateMessage(AValue: TMessageEvent);
begin
  if FOnUpdateMessage=AValue then Exit;
  FOnUpdateMessage:=AValue;
end;

procedure TWebhookAction.SetHelpText(AValue: String);
begin
  if FHelpText=AValue then Exit;
  FHelpText:=AValue;
end;

function TWebhookAction.GetCommandHandlers(const Command: String): TCommandEvent;
begin
  Result:=FCommandHandlers.Items[Command];
end;

procedure TWebhookAction.SetCommandHandlers(const Command: String;
  AValue: TCommandEvent);
begin
  FCommandHandlers.Items[Command]:=AValue;
end;

procedure TWebhookAction.SetLogger(AValue: TEventLog);
begin
  if FLogger=AValue then Exit;
  FLogger:=AValue;
end;

function TWebhookAction.IsSimpleUser: Boolean;
begin
  if Assigned(FCurrentUser) then
    Result:=FUserPermissions.Values[IntToStr(FCurrentUser.ID)]=EmptyStr
  else
    Result:=True;
end;

procedure TWebhookAction.DoCallbackQuery;
begin
  if not IsSimpleUser then
  begin
    if AnsiStartsStr('GetStat ', UpdateObj.CallbackQuery.Data) then
      DoCallbackQueryStat;
    if AnsiStartsStr('GetStatFile ', UpdateObj.CallbackQuery.Data) then
      DoCallbackQueryStat(True);
  end;
  StatLog(UpdateObj.CallbackQuery.Data, utCallbackQuery);
  if Assigned(FOnCallbackQuery) then
    FOnCallbackQuery(Self, UpdateObj.CallbackQuery);
end;

procedure TWebhookAction.DoCallbackQueryStat(SendFile: Boolean = False);
begin
  DoStat(ExtractDelimited(2, UpdateObj.CallbackQuery.Data, [' ']), SendFile);
end;

procedure TWebhookAction.DoGetStat(ADate: TDate = 0; SendFile: Boolean = false);
var
  StatFile: TStringList;
  Msg: String;
  AFileName: String;
  i: Integer;
  ReplyMarkup: TReplyMarkup;
begin
  if IsSimpleUser then
  Exit;
  ReplyMarkup:=TReplyMarkup.Create;
  try
    ReplyMarkup.InlineKeyBoard:=CreateInlineKeyboardStat(SendFile);
    if SendFile then
      SendStatLog(ADate, ReplyMarkup)
    else begin
      StatFile:=TStringList.Create;
      try
        AFileName:=StatLogger.GetFileNameFromDate(ADate);
        FtgSender.RequestWhenAnswer:=True;
        try
          if FileExists(AFileName) then
          begin
            StatFile.LoadFromFile(AFileName);
            Msg:='';
            for i:=StatFile.Count-1 downto StatFile.Count-20 do
            begin
              if i<0 then
                Break;
              Msg+=StatFile[i]+LineEnding;
            end;
            EditOrSendMessage(Msg, pmHTML, ReplyMarkup, True);
          end
          else
            EditOrSendMessage('Statistics for this date not found', pmDefault, ReplyMarkup, True);
        except
          EditOrSendMessage('Error: failed to load statistics file', pmDefault, ReplyMarkup);
        end;
      finally
        StatFile.Free;
      end;
    end;
  finally
    ReplyMarkup.Free;
  end;
end;

procedure TWebhookAction.DoMessageHandler;
var
  lCommand, Txt, S: String;
  lMessageEntityObj: TTelegramMessageEntityObj;
  H: TCommandEvent;
begin
  Txt:=UpdateObj.Message.Text;
  StatLog(Txt, utMessage);
  for lMessageEntityObj in UpdateObj.Message.Entities do
  begin
    if (lMessageEntityObj.TypeEntity = 'bot_command') and (lMessageEntityObj.Offset = 0) then
    begin
      lCommand := Copy(Txt, lMessageEntityObj.Offset, lMessageEntityObj.Length);
      if FCommandHandlers.contains(lCommand) then
      begin
        H:=FCommandHandlers.Items[lCommand];
        H(Self, lCommand, UpdateObj.Message);
        Exit;
      end;
      FtgSender.RequestWhenAnswer:=True;
      if lCommand = '/help' then
      begin
        FtgSender.sendMessage(FCurrentChatID, FHelpText);
        Exit;
      end;
      if lCommand = '/start' then
      begin
        FtgSender.sendMessage(FCurrentChatID, FStartText);
        Exit;
      end;
      if not IsSimpleUser then
      begin
        if lCommand = '/stat' then
        begin
          S:=RightStr(Txt, Length(Txt)-(lMessageEntityObj.Length-lMessageEntityObj.Offset));
          if S<>EmptyStr then
            DoStat(S)
          else
            SendStatInlineKeyboard;
          Exit;
        end;
        if lCommand = '/statf' then
        begin
          S:=RightStr(Txt, Length(Txt)-(lMessageEntityObj.Length-lMessageEntityObj.Offset));
          if S<>EmptyStr then
            DoStat(S, True)
          else
            SendStatInlineKeyboard(True);
          Exit;
        end;
        if lCommand = '/terminate' then
        begin
          FtgSender.sendMessage(FCurrentChatID, 'Bot app is closed');
          BrookApp.Terminate;
          Exit;
        end;
      end;
    end;
  end;
  if Assigned(FOnUpdateMessage) then
    FOnUpdateMessage(Self, UpdateObj.Message);
end;

procedure TWebhookAction.DoStat(SDate: String = 'today'; SendFile: Boolean = false);
var
  FDate: TDate;
begin
  if not Assigned(FStatLogger) then
    Exit;
  SDate:=Trim(SDate);
  if (SDate='today') or (SDate=EmptyStr) then
    FDate:=Date
  else
    if SDate='yesterday' then
      FDate:=Date-1
    else
      if not TryStrToDate(SDate, FDate, StatDateFormat) then
      begin
        FtgSender.RequestWhenAnswer:=True;
        FtgSender.sendMessage(FCurrentChatID, 'Please enter the date in format: dd-mm-yyyy');
        Exit;
      end;
  DoGetStat(FDate, SendFile);
end;

procedure TWebhookAction.SendStatLog(ADate: TDate = 0; AReplyMarkup: TReplyMarkup = nil);
var
  AFileName: String;
begin
  if ADate=0 then
    ADate:=sysutils.Date;
  AFileName:=StatLogger.GetFileNameFromDate(ADate);
  if FileExists(AFileName) then
  begin
    FtgSender.RequestWhenAnswer:=False;
    FtgSender.sendDocumentByFileName(FCurrentChatID, AFileName, 'Statistics for '+DateToStr(ADate));
  end
  else
  begin
    FtgSender.RequestWhenAnswer:=True;
    EditOrSendMessage('Statistics for this date not found', pmDefault, AReplyMarkup, True);
  end;
end;

procedure TWebhookAction.SendStatInlineKeyboard(SendFile: Boolean);
var
  ReplyMarkup: TReplyMarkup;
begin
  ReplyMarkup:=TReplyMarkup.Create;
  try
    ReplyMarkup.InlineKeyBoard:=CreateInlineKeyboardStat(SendFile);
    FtgSender.RequestWhenAnswer:=True;
    FtgSender.sendMessage(FCurrentChatID,
      'Select statistics by pressing the button. In addition, the available commands:'+
      LineEnding+'/stat <i>day</i> - the last records for a specified <i>date</i>, '+
      '/statf <i>date</i> - statistics file for the <i>date</i>,'+LineEnding+
      'where <i>date</i> is <i>today</i> or <i>yesterday</i> or in format <i>dd-mm-yyyy</i>',
      pmHTML, True, ReplyMarkup);
  finally
    ReplyMarkup.Free;
  end;
end;

procedure TWebhookAction.LogMessage(Sender: TObject; EventType: TEventType; const Msg: String);
begin
  if Assigned(FLogger) then
    Logger.Log(EventType, Msg);
end;

procedure TWebhookAction.StatLog(const AMessage: String; UpdateType: TUpdateType);
var
  EscMsg: String;
begin
  EscMsg:=StringReplace(AMessage, '"', '_', [rfReplaceAll]);
  EscMsg:=StringReplace(AMessage, LineEnding, '//', [rfReplaceAll]);
  if Length(EscMsg)>150 then
    SetLength(EscMsg, 150);
  if IsSimpleUser then
    if Assigned(FCurrentUser)then
      StatLogger.Log(['@'+FCurrentUser.Username, FCurrentUser.First_name, FCurrentUser.Last_name,
        FCurrentUser.Language_code, UpdateTypeAliases[UpdateType], '"'+EscMsg+'"'])
    else
      StatLogger.Log(['', '', '', '', UpdateTypeAliases[UpdateType], '"'+EscMsg+'"'])
end;

{ Sometimes, if the message is sent to the result of the CallBack call,
it is desirable not to create a new message and edit the message from which the call came }
procedure TWebhookAction.EditOrSendMessage(const AMessage: String;
  AParseMode: TParseMode; ReplyMarkup: TReplyMarkup; TryEdit: Boolean);
begin
  if TryEdit then
  begin
    TryEdit:=False;
    if Assigned(UpdateObj.CallbackQuery) then
      if Assigned(UpdateObj.CallbackQuery.Message) then
        TryEdit:=True;
  end;
  if not TryEdit then
    Sender.sendMessage(CurrentChatID, AMessage, AParseMode, True, ReplyMarkup)
  else
    Sender.editMessageText(AMessage, CurrentChatID, UpdateObj.CallbackQuery.Message.MessageId,
      AParseMode, False, '', ReplyMarkup);
end;

function TWebhookAction.CreateInlineKeyboardStat(SendFile: Boolean): TJSONArray;
var
  btns: TInlineKeyboardButtons;
  FileApp: String;
begin
  if SendFile then
    FileApp:='File'
  else
    FileApp:='';
  btns:=TInlineKeyboardButtons.Create;
  btns.AddButtons(['Today', 'GetStat'+FileApp+' today',
    'Yesterday', 'GetStat'+FileApp+' yesterday']);
  Result:=TJSONArray.Create;
  Result.Add(btns);
end;

constructor TWebhookAction.Create;
begin
  inherited Create;
  FCurrentUser:=nil;
  FUserPermissions:=TStringList.Create;
  FUserPermissions.Sorted:=True;
  FUserPermissions.Duplicates:=dupIgnore;
  FStatLogger:=TtgStatLog.Create(nil);
  FStatLogger.Active:=False;
  FtgSender:=TTelegramSender.Create(FToken);
  FtgSender.OnLogMessage:=@LogMessage;
  FCommandHandlers:=TCommandHandlersMap.create;
end;

destructor TWebhookAction.Destroy;
begin
  FCommandHandlers.Free;
  FtgSender.Free;
  FStatLogger.Free;
  FUserPermissions.Free;
  if Assigned(UpdateObj) then
    UpdateObj.Free;
  inherited Destroy;
end;

procedure TWebhookAction.Post;
var
  Msg: String;
  lParser: TJSONParser;
begin
  Msg:=TheRequest.Content;
  LogMessage(Self, etDebug, 'Recieve the update (Webhook): '+Msg);
  if Msg<>EmptyStr then
  begin
    lParser := TJSONParser.Create(Msg, DefaultOptions);
    try
      try
        UpdateObj :=
          TTelegramUpdateObj.CreateFromJSONObject(lParser.Parse as TJSONObject) as TTelegramUpdateObj;
      except
      end;
    finally
      lParser.Free;
    end;
    if Assigned(UpdateObj) then
    begin
      if Assigned(UpdateObj.Message) then
      begin
        FCurrentChatID:=UpdateObj.Message.ChatId;
        FCurrentUser:=UpdateObj.Message.From;
        DoMessageHandler;
      end;
      if Assigned(UpdateObj.CallbackQuery) then
      begin
        FCurrentChatID:=UpdateObj.CallbackQuery.Message.ChatId;
        FCurrentUser:=UpdateObj.CallbackQuery.From;
        DoCallbackQuery;
      end;
      TheResponse.ContentType:=BROOK_HTTP_CONTENT_TYPE_APP_JSON;
      Write(FtgSender.RequestBody);
    end;
  end;
end;

end.
