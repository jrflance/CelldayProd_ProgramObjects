--liquibase formatted sql

--changeset Felipe Serrano:1SDF411-4A51-46CC-8B43-WD16521QRT stripComments:false runOnChange:true endDelimiter:/

-- =============================================
--             :
--    Author   : John Rose
--             :
-- Create Date : 11/25/2015
--             :
-- Description : Reports login attempts for a given account ID for the last 7 days.
--             :
--  JR20151223 : Changed @StartDate to be current date minus 7 days.
--  JR20160922 : Architecture change: tblLoginLogs table was moved to [Logs] schema
--             : (from [Fraud]).
--  JR20160926 : LEFT JOIN on Users because User_ID not always logged (yet).
--  LZ20181121 : Adding cellday_history data to extend to 7 days
--             : EXEC [Report].[P_Report_Login_Attempts_By_Account] 2, 35432--37388--23177
--             :
--  NG20210212 : LEFT JOIN on tblLoginType
--	           : Added the following columns: Login Type, Platform, Device Status
--             : Extended the Date Range from 7 to 14 days
--             :
-- KMH20210621 : LEFT JOIN Logs.tblLoginLogsDevice - at this time, no history capture for this table
--             : case when update from lg.FingerprintId to ld.DeviceInfoBlocked per DIR21-447
-- =============================================
CREATE OR ALTER PROCEDURE [Report].[P_Report_Login_Attempts_By_Account]
    (
        @sessionID INT,
        @accountID INT
    )
AS

------Testing
--DECLARE
--	@SessionID INT = 155536
--	, @AccountID int = 28271

BEGIN

    SET NOCOUNT ON;
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

    BEGIN TRY
        --	Old Error HANDling
        --     IF @sessionID <> 2
        --     BEGIN
        --SELECT 'This report is restricted by account ID. Please see your' AS [Error] UNION
        --         SELECT '     T-Cetra representative if you need access!'          AS [Error]
        --RETURN
        --     END


        DECLARE @JobID INT = -1;

        DECLARE @RunMA INT = IIF(@SessionID = @JobID, 2, @SessionID);

        IF object_id(N'tempdb..#Merchant') IS NOT NULL
            DROP TABLE #Merchant;

        CREATE TABLE #Merchant
        (
            Account_id INT
        );

        DECLARE @PHid HIERARCHYID = (SELECT Hierarchy FROM dbo.Account WHERE Account_ID = @RunMA);

        IF len(isnull(@AccountID, '')) > 0
            BEGIN
                IF
                    NOT EXISTS
                    (
                        SELECT 1
                        FROM Account AS a
                        JOIN (SELECT id FROM dbo.fnSplitter(@AccountID)) AS d ON a.Account_ID = d.ID
                    )
                    BEGIN
                        SELECT
                            'Invalid Account ID. Please check your submitted Account ID AND try again.' AS [Error];
                        RETURN;
                    END;

                IF
                    EXISTS
                    (
                        SELECT 1
                        FROM dbo.Account AS a
                        JOIN (SELECT id FROM dbo.fnSplitter(@AccountID)) AS d ON a.Account_ID = d.ID
                        WHERE
                            a.AccountType_ID IN (2, 11)
                            AND a.Hierarchy.IsDescendantOf(@PHid) = 0
                    )
                    BEGIN
                        SELECT
                            'The given accounts does not belong to you(or any one of your sub-master agents).'
                                AS [Error]
                        UNION
                        SELECT '     You are not allowed access.' AS [Error];
                        RETURN;
                    END;
                ELSE
                    BEGIN
                        INSERT INTO #Merchant
                        (
                            Account_id
                        )
                        SELECT id FROM dbo.fnSplitter(@AccountID) AS i
                        WHERE
                            NOT EXISTS
                            (
                                SELECT 1 FROM #Merchant AS m WHERE m.Account_id = i.ID
                            );
                    END;
            END;


        DECLARE
            @LID INT = (
                SELECT min(llh.LoginLogId) FROM CellDay_history.Logs.tblLoginLogs AS llh
                WHERE llh.LogDate >= dateadd(DAY, -14, getdate())
            )
        DECLARE
            @maxLID INT = (
                SELECT max(LoginLogId) FROM CellDay_history.Logs.tblLoginLogs
            )
        SELECT
            lg.Account AS [Account ID],
            ac.Account_Name AS [Account Name],
            ISNULL(ur.UserName, '') AS [User Name],
            CONVERT(CHAR(19), lg.LogDate, 120) AS [Attempted On],
            CASE
                WHEN lg.Successful = 0 THEN 'Failed'
                ELSE 'Successful'
            END AS [Result],

            lt.LoginTypeDescription AS [Login Type],

            CASE
                WHEN lg.Platform = 'VP' AND lg.SubPlatform = '' THEN 'Vidapay'
                WHEN lg.Platform = 'VP' AND lg.SubPlatform = 'DAP' THEN 'TFDAP'
                WHEN lg.Platform = 'CRM' THEN 'CRM'
            END AS [Platform],
            lg.IpAddress AS [IP Address],
            CASE
                WHEN lg.LoginType = 1 AND ld.DeviceInfoBlocked = 0 THEN 'Device Info Available'
                WHEN lg.LoginType = 1 AND ld.DeviceInfoBlocked = 1 THEN 'Device Info Blocked'
                WHEN lg.LoginType = 3 THEN 'Device Info Captured'
                ELSE ''
            END AS [Device Status]
        FROM Logs.tblLoginLogs AS lg
        JOIN Account AS ac ON lg.Account = ac.Account_ID
        JOIN #Merchant AS m ON m.Account_id = ac.Account_ID
        LEFT JOIN Users AS ur ON lg.UserID = ur.User_ID
        LEFT JOIN Logs.tblLoginType AS lt ON lt.LoginTypeId = lg.LoginType
        LEFT JOIN Logs.tblLoginLogsDevice AS ld ON ld.LoginLogId = lg.LoginLogId
        WHERE lg.LoginLogId > @maxLID
        UNION ALL
        SELECT
            lg.Account AS [Account ID],
            ac.Account_Name AS [Account Name],
            ISNULL(ur.UserName, '') AS [User Name],
            CONVERT(CHAR(19), lg.LogDate, 120) AS [Attempted On],
            CASE
                WHEN lg.Successful = 0 THEN 'Failed'
                ELSE 'Successful'
            END AS [Result],

            lt.LoginTypeDescription AS [Login Type],

            CASE
                WHEN lg.Platform = 'VP' AND lg.SubPlatform = '' THEN 'Vidapay'
                WHEN lg.Platform = 'VP' AND lg.SubPlatform = 'DAP' THEN 'TFDAP'
                WHEN lg.Platform = 'CRM' THEN 'CRM'
            END AS [Platform],
            lg.IpAddress AS [IP Address],
            CASE
                WHEN lg.LoginType = 1 AND ld.DeviceInfoBlocked = 0 THEN 'Device Info Available'
                WHEN lg.LoginType = 1 AND ld.DeviceInfoBlocked = 1 THEN 'Device Info Blocked'
                WHEN lg.LoginType = 3 THEN 'Device Info Captured'
                ELSE ''
            END AS [Device Status]
        FROM CellDay_history.Logs.tblLoginLogs AS lg
        JOIN Account AS ac ON lg.Account = ac.Account_ID
        JOIN #Merchant AS m ON m.Account_id = ac.Account_ID
        LEFT JOIN Users AS ur ON lg.UserID = ur.User_ID
        LEFT JOIN Logs.tblLoginType AS lt ON lt.LoginTypeId = lg.LoginType
        LEFT JOIN Logs.tblLoginLogsDevice AS ld ON ld.LoginLogId = lg.LoginLogId

        WHERE lg.LoginLogId > @LID
        ORDER BY CONVERT(CHAR(19), lg.LogDate, 120) DESC

    END TRY
    BEGIN CATCH
        SELECT ERROR_NUMBER() AS ErrorNumber, -- noqa: LT02
            ERROR_MESSAGE() AS ErrorMessage;
    END CATCH
END
-- noqa: disable=all
/
