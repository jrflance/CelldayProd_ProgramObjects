-- =============================================
-- Author:Brandon Stahl
-- Create date: 2024-06-25
-- Description: Updates account white listed Ips from file feed
-- =============================================
CREATE OR ALTER PROCEDURE [Account].[P_UpdateAccountIps]
    (
        @TopParentAccountId INT
    )
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;

        DECLARE
            @IPv4Regex VARCHAR(400) = '^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.' +
            '(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.' +
            '(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.' +
            '(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9]))' +
            '(;(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.' +
            '(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.' +
            '(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])\.' +
            '(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9]))*$'

        DROP TABLE IF EXISTS #AccountIpWhiteListResults;

        CREATE TABLE #AccountIpWhiteListResults
        (
            AccountId VARCHAR(100),
            IPAddresses VARCHAR(500),
            [Status] VARCHAR(100),
            [Message] VARCHAR(100),
            IntAccountId INT
        );

        DROP TABLE IF EXISTS #AccountIpWhiteList;

        CREATE TABLE #AccountIpWhiteList
        (
            AccountId VARCHAR(100),
            IPAddresses VARCHAR(500),
            IntAccountId INT
        );
        CREATE NONCLUSTERED INDEX IX_AccountIpWhiteList_IntAccountId
            ON #AccountIpWhiteList (IntAccountId);

        INSERT INTO #AccountIpWhiteList
        (
            AccountId,
            IPAddresses,
            IntAccountId
        )
        SELECT
            i.AccountId,
            i.IPAddresses,
            CASE
                WHEN TRY_CAST(TRIM(i.AccountId) AS INT) IS NULL THEN -1
                ELSE i.AccountId
            END AS IntAccountId
        FROM Upload.tblAccountIpWhiteList AS i
        WHERE i.ProcessAccountId = @TopParentAccountId;

        DELETE i
        FROM Upload.tblAccountIpWhiteList AS i
        WHERE i.ProcessAccountId = @TopParentAccountId;


        DROP TABLE IF EXISTS #MerchantAccountIds;

        CREATE TABLE #MerchantAccountIds (AccountID INT);
        CREATE NONCLUSTERED INDEX IX_MerchantAccountIds_AccountId
            ON #MerchantAccountIds (AccountId);

        INSERT INTO #MerchantAccountIds (AccountID)
        EXEC Account.P_Account_GetAccountList
            @AccountID = @TopParentAccountId,
            @UserID = 2,
            @AccountTypeID = '2,11',
            @AccountStatusID = '0,1,2,3,4,5,6',
            @Simplified = 1;

        INSERT INTO #AccountIpWhiteListResults
        (
            AccountId,
            IPAddresses,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            i.AccountId,
            i.IPAddresses,
            'Failed' AS [Status],
            'Error: Invalid Account Id' AS [Message],
            i.IntAccountId
        FROM #AccountIpWhiteList AS i
        WHERE i.IntAccountId = -1;

        INSERT INTO #AccountIpWhiteListResults
        (
            AccountId,
            IPAddresses,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            i.AccountId,
            i.IPAddresses,
            'Failed' AS [Status],
            'Error: Account Id must be in MA tree' AS [Message],
            i.IntAccountId
        FROM #AccountIpWhiteList AS i
        WHERE
            EXISTS (
                SELECT 1
                FROM #AccountIpWhiteList AS i1
                WHERE i1.IntAccountId = i1.IntAccountId
                GROUP BY i1.IntAccountId
                HAVING COUNT(1) > 1
            );

        INSERT INTO #AccountIpWhiteListResults
        (
            AccountId,
            IPAddresses,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            i.AccountId,
            i.IPAddresses,
            'Failed' AS [Status],
            'Error: Account is not in Master Agent Tree' AS [Message],
            i.IntAccountId
        FROM #AccountIpWhiteList AS i
        WHERE
            NOT EXISTS (SELECT 1 FROM #MerchantAccountIds AS ma WHERE ma.AccountID = i.IntAccountId)
            AND NOT EXISTS (SELECT 1 FROM #AccountIpWhiteListResults AS ir WHERE ir.IntAccountId = i.IntAccountId);

        INSERT INTO #AccountIpWhiteListResults
        (
            AccountId,
            IPAddresses,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            i.AccountId,
            i.IPAddresses,
            'Failed' AS [Status],
            'Error: Ip address must a semicolon separated list of IPv4 or empty' AS [Message],
            i.IntAccountId
        FROM #AccountIpWhiteList AS i
        WHERE
            ISNULL(i.IPAddresses, '') NOT LIKE @IPv4Regex
            AND ISNULL(i.IPAddresses, '') != ''
            AND NOT EXISTS (SELECT 1 FROM #AccountIpWhiteListResults AS ir WHERE ir.IntAccountId = i.IntAccountId);

        BEGIN TRANSACTION
        UPDATE a
        SET
            a.Restrict_IPAddress = i.IPAddresses,
            a.Update_UserID = CURRENT_USER,
            a.Update_Tms = GETDATE()
        FROM dbo.Account AS a
        JOIN #AccountIpWhiteList AS i ON i.IntAccountId = a.Account_ID
        WHERE NOT EXISTS (SELECT 1 FROM #AccountIpWhiteListResults AS ir WHERE ir.IntAccountId = i.IntAccountId);

        COMMIT

        INSERT INTO #AccountIpWhiteListResults
        (
            AccountId,
            IPAddresses,
            [Status],
            [Message],
            IntAccountId
        )
        SELECT
            i.AccountId,
            i.IPAddresses,
            'UPDATED' AS [Status],
            'Success: User Ips were updated' AS [Message],
            i.IntAccountId
        FROM #AccountIpWhiteList AS i
        WHERE NOT EXISTS (SELECT 1 FROM #AccountIpWhiteListResults AS ir WHERE ir.IntAccountId = i.IntAccountId);

        --Support for parent sproc
        IF OBJECT_ID('tempdb..#final') IS NOT NULL
            BEGIN
                INSERT INTO #final
                SELECT
                    AccountId AS AccountId,
                    IPAddresses AS IPAddresses,
                    [Status] AS [Status],
                    [Message] AS [Message]
                FROM #AccountIpWhiteListResults
            END
        ELSE
            BEGIN
                SELECT
                    AccountId AS AccountId,
                    IPAddresses AS IPAddresses,
                    [Status] AS [Status],
                    [Message] AS [Message]
                FROM #AccountIpWhiteListResults
            END

    END TRY
    BEGIN CATCH
        ROLLBACK;
        DELETE i
        FROM Upload.tblAccountIpWhiteList AS i
        WHERE i.ProcessAccountId = @TopParentAccountId;
        THROW;
    END CATCH
END;
