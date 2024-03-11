--liquibase formatted sql

--changeset Felipe Serrano:16CC7EA4-4E57-46CC-8B43-9329BAAE0BD9 stripComments:false runOnChange:true endDelimiter:/

-- =============================================
--      Author : John Rose
--             :
--     Created : 2014-12-29
--             :
-- Description : This will unlock an account (make IsLocked Flag = 0 in the [Security].[tblAccountLock] table)
--             : given an Account_ID. It assumes only one record will be locked (IsLocked = 1) for however
--             : many records may have the same account ID.
--             :
--       Usage : EXEC [Report].[P_Report_Unlock_Account_In_AccountLock_Table] 13379, 29531
--		 V1. Ch 20160920 optimization. Removal of the isolation and transaction block as there is only one update. ticket #INC-58872
--  FS20240305 : Added error handling for MA selfservice reports
-- =============================================
CREATE OR ALTER PROCEDURE [Report].[P_Report_Unlock_Account_In_AccountLock_Table]
    (
        @AccountID INT,
        @UserID INT
    )
AS

-- Testing
--DECLARE @AccountId INT = 28271
--DECLARE @UserID INT = 1243
--DECLARE @SessionID INT = 155536

BEGIN
    BEGIN TRY

        DECLARE @SessionID INT;

        SELECT DISTINCT @SessionID = u.Account_ID
        FROM Users AS u
        WHERE u.User_id = @UserID

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
                            'Invalid Account ID. Please check your submitted Account ID and try again.' AS [Error];
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

        IF
            EXISTS (
                SELECT 1
                FROM [Security].[tblAccountLock] AS al WITH (READUNCOMMITTED)
                JOIN #Merchant AS m ON m.Account_id = al.Account_ID
                WHERE al.IsLocked = 1
            )
            BEGIN
            -- V1. removal of the isolation level and prerequisite of the filtered index [IX_SecuritytblAcountLock_LockedAccountId]
                UPDATE [Security].[tblAccountLock]
                SET
                    IsLocked = 0,
                    UnlockUser = @UserID,
                    UnLockDate = GETDATE()
                WHERE Account_ID = @AccountID AND IsLocked = 1

                -- v1. read uncommitted
                SELECT TOP 1
                    al.Account_ID AS [Account ID],
                    CASE
                        WHEN al.IsLocked = 1 THEN 'Locked'
                        ELSE 'Unlocked'
                    END AS [Status],
                    al.UnlockUser AS [Update User ID],
                    al.UnLockDate AS [Update Timestamp]
                FROM [Security].[tblAccountLock] AS al WITH (READUNCOMMITTED)
                JOIN #Merchant AS m ON m.Account_id = al.Account_ID
                ORDER BY al.UnLockDate DESC

            END
        ELSE
            BEGIN
                SELECT 'Account ID ''' + CAST(@AccountID AS NVARCHAR(10)) + ''' is not currently locked!' AS [Error]
            END

    END TRY

    BEGIN CATCH
        SELECT
            ERROR_NUMBER() AS ErrorNumber,
            ERROR_MESSAGE() AS ErrorMessage;
    END CATCH

END
-- noqa: disable=all
/
