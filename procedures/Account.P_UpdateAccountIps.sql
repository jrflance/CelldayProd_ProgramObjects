--liquibase formatted sql

--changeset  BrandonStahl:4313f452-1479-4d06-b412-7d6be78b35a4 stripComments:false runOnChange:true splitStatements:false

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

        IF NOT EXISTS (SELECT 1 FROM #AccountIpWhiteList)
            BEGIN
                RETURN;
            END;

        DELETE i
        FROM Upload.tblAccountIpWhiteList AS i
        WHERE i.ProcessAccountId = @TopParentAccountId;

        DROP TABLE IF EXISTS #CleanAccountIps;

        CREATE TABLE #CleanAccountIps
        (
            AccountId VARCHAR(100),
            IPAddress VARCHAR(500),
        );
        CREATE NONCLUSTERED INDEX IX_AccountIp_AccountId
            ON #CleanAccountIps (AccountId);

        INSERT INTO #CleanAccountIps
        (
            AccountId,
            IPAddress
        )
        SELECT
            a.AccountId,
            REPLACE(REPLACE(TRIM(i.[value]), CHAR(13), ''), CHAR(10), '') AS IPAddress
        FROM #AccountIpWhiteList AS a
        CROSS APPLY STRING_SPLIT(a.IPAddresses, ';') AS i;

        DROP TABLE IF EXISTS #AggregatedCleanIps;

        SELECT
            c.AccountId,
            STRING_AGG(CAST(c.IPAddress AS VARCHAR(MAX)), ';') AS CleanIps
        INTO #AggregatedCleanIps
        FROM #CleanAccountIps AS c
        GROUP BY c.AccountId

        UPDATE a
        SET a.IPAddresses = ci.CleanIps
        FROM #AccountIpWhiteList AS a
        JOIN #AggregatedCleanIps AS ci ON a.AccountId = ci.AccountId

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

        DROP TABLE IF EXISTS #CurrentAccountIps;

        SELECT a.Account_ID AS AccountId, a.Restrict_IPAddress AS IpAddresses
        INTO #CurrentAccountIps
        FROM dbo.Account AS a
        JOIN #MerchantAccountIds AS ma ON ma.AccountID = a.Account_ID

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
            'FAILED' AS [Status],
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
            'FAILED' AS [Status],
            'Error: Account Id must be distinct per file' AS [Message],
            i.IntAccountId
        FROM #AccountIpWhiteList AS i
        WHERE
            EXISTS (
                SELECT 1
                FROM #AccountIpWhiteList AS i1
                WHERE i1.IntAccountId = i.IntAccountId
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
            'FAILED' AS [Status],
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
            'FAILED' AS [Status],
            'Error: Exceeds 25 Ip per account limit' AS [Message],
            i.IntAccountId
        FROM #AccountIpWhiteList AS i
        WHERE
            EXISTS (SELECT 1 FROM #CleanAccountIps AS a WHERE a.AccountId = i.AccountId HAVING COUNT(1) > 25)
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
            'FAILED' AS [Status],
            'Error: Ip address must a semicolon separated list of IPv4 or empty' AS [Message],
            i.IntAccountId
        FROM #AccountIpWhiteList AS i
        WHERE
            EXISTS (SELECT 1 FROM #CleanAccountIps AS a WHERE i.AccountId = a.AccountId AND dbo.IsValidIPv4(a.IPAddress) = 0)
            AND ISNULL(i.IPAddresses, '') != ''
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
            'NO CHANGE' AS [Status],
            '' AS [Message],
            i.IntAccountId
        FROM #AccountIpWhiteList AS i
        JOIN #CurrentAccountIps AS c ON c.AccountID = i.AccountId
        WHERE
            ISNULL(i.IPAddresses, '') = ISNULL(c.IpAddresses, '')
            AND NOT EXISTS (SELECT 1 FROM #AccountIpWhiteListResults AS ir WHERE ir.IntAccountId = i.IntAccountId);

        BEGIN TRANSACTION
        UPDATE a
        SET
            a.Restrict_IPAddress = ISNULL(i.IPAddresses, ''),
            a.Update_UserID = CURRENT_USER,
            a.Update_Tms = GETDATE()
        FROM dbo.Account AS a
        JOIN #CurrentAccountIps AS c ON a.Account_ID = c.AccountId
        LEFT JOIN #AccountIpWhiteList AS i ON i.IntAccountId = a.Account_ID
        WHERE NOT EXISTS (SELECT 1 FROM #AccountIpWhiteListResults AS ir WHERE ir.IntAccountId = ISNULL(i.IntAccountId, -2));

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
            c.AccountId,
            ISNULL(i.IPAddresses, '') AS IPAddresses,
            'UPDATED' AS [Status],
            'Success: User Ips were updated' AS [Message],
            i.IntAccountId
        FROM #CurrentAccountIps AS c
        LEFT JOIN #AccountIpWhiteList AS i ON i.IntAccountId = c.AccountId
        WHERE
            NOT EXISTS (SELECT 1 FROM #AccountIpWhiteListResults AS ir WHERE ir.IntAccountId = ISNULL(i.IntAccountId, -2))
            AND ISNULL(c.IpAddresses, '') != ISNULL(i.IPAddresses, '');

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
